defmodule JX.GoogleMeetTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.CallHandoffs.CallHandoff
  alias JX.CLI
  alias JX.GoogleMeet
  alias JX.GoogleMeet.AuthProfile
  alias JX.GoogleMeet.Session
  alias JX.Repo

  setup do
    Repo.delete_all(Session)
    Repo.delete_all(AuthProfile)
    Repo.delete_all(CallHandoff)
    :ok
  end

  test "configures personal auth and exchanges a PKCE OAuth code" do
    assert {:ok, %AuthProfile{} = profile} =
             GoogleMeet.configure_auth(%{
               profile: "personal",
               email: "me@example.com",
               client_id: "client-123.apps.googleusercontent.com",
               redirect_uri: "http://127.0.0.1:9876/callback",
               artifacts: true
             })

    assert profile.name == "personal"
    assert profile.status == "configured"
    assert "https://www.googleapis.com/auth/drive.meet.readonly" in Jason.decode!(profile.scopes)

    assert {:ok, auth} = GoogleMeet.auth_url("personal", login_hint: "me@example.com")
    assert auth.auth_url =~ "https://accounts.google.com/o/oauth2/v2/auth?"
    assert auth.auth_url =~ "code_challenge_method=S256"
    assert auth.profile.status == "pending"

    http_client = fn :post, "https://oauth2.googleapis.com/token", headers, body ->
      assert {"content-type", "application/x-www-form-urlencoded"} in headers
      assert body =~ "grant_type=authorization_code"
      assert body =~ "code=oauth-code"
      assert body =~ "code_verifier="

      {:ok,
       %{
         status: 200,
         body: %{
           "access_token" => "access-token",
           "refresh_token" => "refresh-token",
           "expires_in" => 3600
         }
       }}
    end

    assert {:ok, exchanged} =
             GoogleMeet.exchange_auth_code("personal", "oauth-code", http_client: http_client)

    assert exchanged.status == "authenticated"
    assert exchanged.token.has_access_token
    assert exchanged.token.has_refresh_token
    assert is_binary(exchanged.token.expires_at)
  end

  test "lists status helpers profiles sessions and auth error paths" do
    assert "command" in GoogleMeet.audio_bridges()
    assert "configured" in GoogleMeet.auth_statuses()
    assert "planned" in GoogleMeet.session_statuses()
    assert "connect" in GoogleMeet.twilio_modes()
    assert "inbound_track" in GoogleMeet.twilio_tracks()

    assert {:error, :google_meet_auth_profile_not_found} = GoogleMeet.get_auth_profile("missing")

    assert {:ok, _alpha} =
             GoogleMeet.configure_auth(%{
               profile: "alpha",
               client_id: "alpha-client",
               scopes: "scope-a, scope-b\nscope-c"
             })

    assert {:ok, _beta} =
             GoogleMeet.configure_auth(%{profile: "beta", client_id: "beta-client"})

    assert [%AuthProfile{name: "alpha"}] = GoogleMeet.list_auth_profiles(limit: 1)

    assert {:error, "google auth profile alpha has no pending OAuth verifier"} =
             GoogleMeet.exchange_auth_code("alpha", "code")

    assert {:ok, errored_alpha} = GoogleMeet.get_auth_profile("alpha")
    assert errored_alpha.status == "error"
    assert errored_alpha.last_error =~ "no pending OAuth verifier"

    assert {:ok, _auth} = GoogleMeet.auth_url("beta")

    http_client = fn :post, "https://oauth2.googleapis.com/token", _headers, _body ->
      {:ok, %{status: 400, body: %{"error" => "invalid_grant"}}}
    end

    assert {:error, "google oauth exchange failed with 400" <> _} =
             GoogleMeet.exchange_auth_code("beta", "bad-code", http_client: http_client)

    assert {:ok, errored_beta} = GoogleMeet.get_auth_profile("beta")
    assert errored_beta.status == "error"
    assert errored_beta.last_error =~ "invalid_grant"

    assert {:ok, planned} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               title: "Filtered session",
               project: "saysure",
               ref: "gm-1"
             })

    assert {:ok, _ended} =
             GoogleMeet.create_session(%{
               meeting: "def-ghij-klm",
               status: "ended",
               project: "other",
               ref: "gm-2"
             })

    assert [%Session{session_id: session_id}] =
             GoogleMeet.list_sessions(
               status: "planned",
               project: "saysure",
               ref: "gm-1",
               meeting_code: "abc-mnop-xyz"
             )

    assert session_id == planned.session_id
    assert {:error, :google_meet_session_not_found} = GoogleMeet.get_session("missing")
    assert {:error, :google_meet_session_not_found} = GoogleMeet.join_plan("missing")
  end

  test "creates a Meet session, handoff, join plan, and Twilio TwiML" do
    assert {:ok, %Session{} = session} =
             GoogleMeet.create_session(
               %{
                 meeting: "https://meet.google.com/abc-mnop-xyz?authuser=0",
                 title: "Planning call",
                 project: "saysure",
                 ref: "s-123",
                 chrome_node: "http://127.0.0.1:9222",
                 paired_chrome_node: "http://127.0.0.1:9223",
                 twilio_stream_url: "wss://voice.example.test/meet",
                 twilio_mode: "start",
                 twilio_track: "both_tracks"
               },
               handoff: true
             )

    assert session.session_id =~ "met-"
    assert session.meeting_code == "abc-mnop-xyz"
    assert session.handoff_id =~ "cal-"

    assert {:ok, plan} = GoogleMeet.join_plan(session)
    assert plan.google.rest_join_supported == false
    assert plan.chrome.primary.launch_command =~ "--remote-debugging-port=9222"
    assert plan.chrome.paired.launch_command =~ "--remote-debugging-port=9223"
    assert plan.twilio.twiml =~ ~s(<Start><Stream)
    assert plan.twilio.twiml =~ ~s(track="both_tracks")
    assert plan.exports.command =~ "jx meet export #{session.session_id}"
  end

  test "join_session persists browser agent runner state through an injected join client" do
    assert {:ok, %Session{} = session} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               title: "Joinable call",
               chrome_node: "browser-agent://primary",
               paired_chrome_node: "browser-agent://paired"
             })

    join_client = fn joined_session, opts ->
      assert joined_session.session_id == session.session_id
      assert opts[:runner] == "browser-agent"

      {:ok,
       %{
         runner: "browser-agent",
         status: "live",
         debug_url: "browser-agent://primary",
         target: %{
           "id" => "tab-primary",
           "type" => "browser-agent",
           "url" => joined_session.meeting_uri
         },
         paired: %{
           target: %{
             "id" => "tab-paired",
             "type" => "browser-agent",
             "url" => joined_session.meeting_uri
           }
         },
         cdp: %{"mode" => "browser-agent"},
         joined?: true,
         join_clicked?: true,
         actions: [%{"name" => "join_meet"}],
         completed_at: DateTime.utc_now()
       }}
    end

    assert {:ok, joined} =
             GoogleMeet.join_session(session,
               runner: "browser-agent",
               join_client: join_client
             )

    assert joined.session.status == "live"
    assert joined.session.chrome_target["id"] == "tab-primary"
    assert joined.session.paired_chrome_target["id"] == "tab-paired"
    assert joined.session.realtime["join_runner"]["runner"] == "browser-agent"
    assert joined.runner.runner == "browser-agent"
    assert joined.runner.joined == true
    assert joined.runner.target["url"] == session.meeting_uri
  end

  test "join_session handles unsupported runners failed joins and joining payloads" do
    assert {:ok, %Session{} = unsupported} =
             GoogleMeet.create_session(%{meeting: "abc-mnop-xyz", title: "Unsupported runner"})

    assert {:error, "unsupported Meet join runner \"nope\""} =
             GoogleMeet.join_session(unsupported, runner: "nope")

    assert {:ok, %Session{} = failing} =
             GoogleMeet.create_session(%{meeting: "def-ghij-klm", title: "Failing join"})

    assert {:error, "join failed"} =
             GoogleMeet.join_session(failing,
               runner: "browser-agent",
               join_client: fn _session, _opts -> {:error, "join failed"} end
             )

    assert {:ok, failed_session} = GoogleMeet.get_session(failing.session_id)
    assert failed_session.status == "failed"

    assert failed_session.realtime |> Jason.decode!() |> Map.fetch!("last_join_error") =~
             "join failed"

    assert {:ok, %Session{} = joining} =
             GoogleMeet.create_session(%{
               meeting: "ghi-jklm-nop",
               title: "Joining payload",
               paired_chrome_target: %{"id" => "previous-paired"}
             })

    assert {:ok, result} =
             GoogleMeet.join_session(joining,
               runner: "browser-agent",
               join_client: fn _session, _opts ->
                 {:ok,
                  %{
                    "runner" => "browser-agent",
                    "status" => "unexpected",
                    "debug_url" => "iab://node",
                    "target" => %{"id" => "joining-tab", "type" => "browser-agent"},
                    "paired" => "bad-paired",
                    "joinClicked" => true,
                    "joined" => false
                  }}
               end
             )

    assert result.session.status == "joining"
    assert result.session.chrome_node == "iab://node"
    assert result.session.paired_chrome_target["id"] == "previous-paired"
    assert result.runner.join_clicked == true
  end

  test "plans starts and consults a Meet realtime voice loop" do
    assert {:ok, %Session{} = session} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               title: "Realtime call",
               project: "saysure",
               ref: "rt-1"
             })

    assert {:ok, plan} =
             GoogleMeet.realtime_plan(session,
               provider: "browser-agent",
               audio_bridge: "command",
               audio_ingress_command: "capture-audio",
               audio_egress_command: "play-audio",
               approve_audio_capture: true,
               approve_speech_output: true
             )

    assert plan.status == "ready"
    assert plan.consult.tool == "openclaw_agent_consult"

    assert {:ok, started} =
             GoogleMeet.start_realtime(
               session,
               %{
                 provider: "browser-agent",
                 audio_bridge: "command",
                 audio_ingress_command: "capture-audio",
                 audio_egress_command: "play-audio"
               },
               approve_audio_capture: true,
               approve_speech_output: true
             )

    assert started.voice_loop["status"] == "planned"
    assert started.session.realtime["voice_loop"]["provider"] == "browser-agent"

    assert {:ok, consult} =
             GoogleMeet.realtime_consult(session.session_id, %{
               transcript: "We decided to review the blocked deployment after CI finishes.",
               decision: "wait for CI",
               follow_up: "review deployment blockers"
             })

    assert consult.handoff.surface == "meet"
    assert consult.handoff.project == "saysure"
    assert consult.handoff.ref == "rt-1"
    assert consult.handoff.summary =~ "blocked deployment"
    assert consult.response.handoff_id == consult.handoff.handoff_id
  end

  test "plans browser-agent realtime against a joined browser tab" do
    assert {:ok, %Session{} = session} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               title: "Browser realtime"
             })

    assert {:ok, joined} =
             GoogleMeet.join_session(session,
               runner: "browser-agent",
               join_client: fn session, _opts ->
                 {:ok,
                  %{
                    runner: "browser-agent",
                    status: "live",
                    debug_url: "iab://codex",
                    target: %{
                      "id" => "meet-tab",
                      "type" => "browser-agent",
                      "url" => session.meeting_uri
                    },
                    cdp: %{"mode" => "browser-agent"},
                    joined?: true,
                    join_clicked?: true,
                    actions: []
                  }}
               end
             )

    assert {:ok, %Session{} = joined_session} = GoogleMeet.get_session(joined.session.session_id)
    assert {:ok, plan} = GoogleMeet.realtime_plan(joined_session)
    assert plan.provider == "browser-agent"
    assert plan.audio_bridge == "browser-agent"
    assert plan.status == "needs_approval"
    assert plan.ingress.mode == "active-tab"
    assert plan.ingress.ready == true
    assert plan.ingress.target["id"] == "meet-tab"
    assert plan.egress.ready == true

    assert {:ok, approved} =
             GoogleMeet.realtime_plan(joined_session,
               approve_audio_capture: true,
               approve_speech_output: true
             )

    assert approved.status == "ready"
  end

  test "realtime planning and start validate provider audio and approval branches" do
    old_openai = System.get_env("OPENAI_API_KEY")

    on_exit(fn ->
      if old_openai,
        do: System.put_env("OPENAI_API_KEY", old_openai),
        else: System.delete_env("OPENAI_API_KEY")
    end)

    assert {:ok, %Session{} = session} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               twilio_stream_url: "wss://voice.example.test/meet",
               twilio_mode: "connect",
               twilio_track: "inbound_track"
             })

    assert {:ok, needs_provider} =
             GoogleMeet.realtime_plan(session,
               provider: "openai_realtime",
               audio_bridge: "twilio"
             )

    assert needs_provider.status == "needs_provider"
    assert needs_provider.ingress.ready == true
    assert needs_provider.egress.ready == true
    assert Enum.any?(needs_provider.constraints, &String.contains?(&1, "Twilio Connect/Stream"))

    System.put_env("OPENAI_API_KEY", "test-key")

    assert {:ok, needs_approval} =
             GoogleMeet.realtime_plan(session,
               provider: "openai-realtime",
               audio_bridge: "twilio"
             )

    assert needs_approval.status == "needs_approval"

    assert {:error, "live Meet realtime requires --approve-audio-capture" <> _} =
             GoogleMeet.start_realtime(session, %{live: true, audio_bridge: "twilio"})

    System.delete_env("OPENAI_API_KEY")

    assert {:error, "Meet realtime loop is needs_provider" <> _} =
             GoogleMeet.start_realtime(
               session,
               %{
                 live: true,
                 provider: "openai-realtime",
                 audio_bridge: "twilio",
                 approve_audio_capture: true,
                 approve_speech_output: true
               }
             )

    assert {:ok, browser_needs_tab} =
             GoogleMeet.realtime_plan(session, audio_bridge: "browser-agent")

    assert browser_needs_tab.status == "needs_audio_ingress"

    assert Enum.any?(
             browser_needs_tab.constraints,
             &String.contains?(&1, "Browser-agent realtime")
           )

    assert {:ok, command_needs_egress} =
             GoogleMeet.realtime_plan(session,
               audio_bridge: "command",
               audio_ingress_command: "capture-audio",
               approve_audio_capture: true,
               approve_speech_output: true
             )

    assert command_needs_egress.status == "needs_audio_egress"

    assert Enum.any?(
             command_needs_egress.constraints,
             &String.contains?(&1, "Command audio bridge")
           )
  end

  test "watches browser captions and creates one consult per new transcript" do
    assert {:ok, %Session{} = session} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               title: "Caption watcher"
             })

    assert {:ok, joined} =
             GoogleMeet.join_session(session,
               runner: "browser-agent",
               join_client: fn session, _opts ->
                 {:ok,
                  %{
                    runner: "browser-agent",
                    status: "live",
                    debug_url: "iab://codex",
                    target: %{
                      "id" => "caption-tab",
                      "type" => "browser-agent",
                      "url" => session.meeting_uri
                    },
                    cdp: %{"mode" => "browser-agent"},
                    joined?: true,
                    join_clicked?: true,
                    actions: []
                  }}
               end
             )

    assert {:ok, %Session{} = joined_session} = GoogleMeet.get_session(joined.session.session_id)

    assert {:ok, _started} =
             GoogleMeet.start_realtime(
               joined_session,
               %{
                 live: true,
                 provider: "browser-agent",
                 audio_bridge: "browser-agent",
                 approve_audio_capture: true,
                 approve_speech_output: true,
                 approve_notes_or_transcription: true
               }
             )

    assert {:ok, %Session{} = ready_session} = GoogleMeet.get_session(joined.session.session_id)

    caption_client = fn _session, _state ->
      {:ok,
       %{
         "captions" => [
           %{
             "speaker" => "User",
             "text" => "Decision: ship after CI turns green.",
             "at" => "2026-04-27T17:00:00Z"
           }
         ]
       }}
    end

    assert {:ok, watched} =
             GoogleMeet.realtime_watch(ready_session,
               caption_client: caption_client,
               iterations: 1,
               min_chars: 5,
               speak: true,
               speech_client: fn text ->
                 assert text =~ "Google Meet abc-mnop-xyz realtime consult"
                 {:ok, %{status: "sent"}}
               end
             )

    assert watched.status == "consulted"
    assert watched.consulted == 1
    assert [%{status: "consulted", handoff: handoff}] = watched.events
    assert handoff.summary =~ "ship after CI"
    assert watched.watcher["last_handoff_id"] == handoff.handoff_id
    assert watched.watcher["last_speech"]["status"] == "sent"
    assert Repo.aggregate(CallHandoff, :count) == 1

    assert {:ok, %Session{} = updated_session} = GoogleMeet.get_session(joined.session.session_id)

    assert {:ok, duplicate} =
             GoogleMeet.realtime_watch(updated_session,
               caption_client: caption_client,
               iterations: 1,
               min_chars: 5
             )

    assert duplicate.status == "idle"
    assert [%{status: "duplicate"}] = duplicate.events
    assert Repo.aggregate(CallHandoff, :count) == 1
  end

  test "realtime watch can ask a consult command and speak its response" do
    assert {:ok, %Session{} = session} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               title: "Command consult"
             })

    assert {:ok, joined} =
             GoogleMeet.join_session(session,
               runner: "browser-agent",
               join_client: fn session, _opts ->
                 {:ok,
                  %{
                    runner: "browser-agent",
                    status: "live",
                    debug_url: "iab://codex",
                    target: %{
                      "id" => "command-tab",
                      "type" => "browser-agent",
                      "url" => session.meeting_uri
                    },
                    cdp: %{"mode" => "browser-agent"},
                    joined?: true,
                    join_clicked?: true,
                    actions: []
                  }}
               end
             )

    assert {:ok, %Session{} = joined_session} = GoogleMeet.get_session(joined.session.session_id)

    assert {:ok, _started} =
             GoogleMeet.start_realtime(
               joined_session,
               %{
                 live: true,
                 provider: "browser-agent",
                 audio_bridge: "browser-agent",
                 approve_audio_capture: true,
                 approve_speech_output: true,
                 approve_notes_or_transcription: true
               }
             )

    command_path = Path.join(System.tmp_dir!(), "jx-meet-consult-#{System.unique_integer()}.sh")
    Process.put(:command_path, command_path)

    File.write!(command_path, """
    #!/bin/sh
    cat >/dev/null
    printf '%s' '{"response":"I can hear you in Meet and will track this thread.","summary":"Meet participant asked Codex to join live.","decisions":["continue live in Meet"],"follow_ups":["keep captions flowing"]}'
    """)

    File.chmod!(command_path, 0o700)

    assert {:ok, ready_session} = GoogleMeet.get_session(joined.session.session_id)

    assert {:ok, watched} =
             GoogleMeet.realtime_watch(ready_session,
               caption_client: fn _session, _state ->
                 {:ok, %{"transcript" => "Can you join this Google Meet and talk with me?"}}
               end,
               consult_command: command_path,
               iterations: 1,
               min_chars: 5,
               speak: true,
               speech_client: fn text ->
                 assert text == "I can hear you in Meet and will track this thread."
                 {:ok, %{status: "sent"}}
               end
             )

    assert [%{handoff: handoff, response: response}] = watched.events
    assert handoff.summary == "Meet participant asked Codex to join live."
    assert response.spoken_summary == "I can hear you in Meet and will track this thread."
    assert watched.watcher["last_speech"]["status"] == "sent"
  after
    if command_path = Process.get(:command_path), do: File.rm(command_path)
  end

  test "realtime watch can use chat files when captions are unavailable" do
    assert {:ok, %Session{} = session} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               title: "Chat input"
             })

    assert {:ok, joined} =
             GoogleMeet.join_session(session,
               runner: "browser-agent",
               join_client: fn session, _opts ->
                 {:ok,
                  %{
                    runner: "browser-agent",
                    status: "live",
                    debug_url: "iab://codex",
                    target: %{
                      "id" => "chat-tab",
                      "type" => "browser-agent",
                      "url" => session.meeting_uri
                    },
                    cdp: %{"mode" => "browser-agent"},
                    joined?: true,
                    join_clicked?: true,
                    actions: []
                  }}
               end
             )

    assert {:ok, %Session{} = joined_session} = GoogleMeet.get_session(joined.session.session_id)

    assert {:ok, _started} =
             GoogleMeet.start_realtime(
               joined_session,
               %{
                 live: true,
                 provider: "browser-agent",
                 audio_bridge: "browser-agent",
                 approve_audio_capture: true,
                 approve_speech_output: true,
                 approve_notes_or_transcription: true
               }
             )

    chat_file = Path.join(System.tmp_dir!(), "jx-meet-chat-#{System.unique_integer()}.json")
    Process.put(:chat_file, chat_file)

    File.write!(
      chat_file,
      Jason.encode!(%{
        "messages" => [
          %{
            "sender" => "User",
            "message" => "Can you answer this through Meet chat instead of captions?",
            "timestamp" => "2026-04-27T18:00:00Z"
          }
        ]
      })
    )

    assert {:ok, ready_session} = GoogleMeet.get_session(joined.session.session_id)

    assert {:ok, watched} =
             GoogleMeet.realtime_watch(ready_session,
               chat_file: chat_file,
               iterations: 1,
               min_chars: 5
             )

    assert watched.status == "consulted"

    assert [%{status: "consulted", source: "chat", messages: [message], handoff: handoff}] =
             watched.events

    assert message["speaker"] == "User"
    assert message["text"] =~ "Meet chat"
    assert handoff.summary =~ "Meet chat"
    assert watched.watcher["last_input_source"] == "chat"
    assert watched.watcher["last_message_count"] == 1
    assert watched.watcher["last_caption_count"] == 0
  after
    if path = Process.get(:chat_file), do: File.rm(path)
  end

  test "realtime watch handles idle short file and injected client error branches" do
    ready_session = ready_realtime_session!("Watch branches")

    assert {:error, "unsupported Meet realtime caption client :bad"} =
             GoogleMeet.realtime_watch(ready_session, caption_client: :bad)

    assert {:error, :capture_failed} =
             GoogleMeet.realtime_watch(ready_session,
               caption_client: fn _session, _state -> {:error, :capture_failed} end
             )

    assert {:error, "could not read Meet caption file" <> _} =
             GoogleMeet.realtime_watch(ready_session,
               caption_file: Path.join(System.tmp_dir!(), "missing-meet-captions.json")
             )

    assert {:ok, idle} =
             GoogleMeet.realtime_watch(ready_session,
               caption_client: fn _session, _state -> {:ok, %{"transcript" => ""}} end
             )

    assert idle.status == "idle"
    assert [%{"reason" => "no_input_text", status: "idle"}] = idle.events

    assert {:ok, refreshed} = GoogleMeet.get_session(ready_session.session_id)

    assert {:ok, too_short} =
             GoogleMeet.realtime_watch(refreshed,
               caption_client: fn _session, _opts, _state -> %{"text" => "tiny"} end,
               min_chars: 10
             )

    assert too_short.status == "idle"
    assert [%{"reason" => "below_min_chars", status: "too_short"}] = too_short.events

    caption_file = Path.join(System.tmp_dir!(), "jx-meet-caption-#{System.unique_integer()}.txt")
    File.write!(caption_file, "This transcript comes from a plain text caption file.")

    try do
      assert {:ok, consulted} =
               GoogleMeet.realtime_watch(refreshed,
                 caption_file: caption_file,
                 min_chars: 10,
                 consult_fun: fn session_id, attrs, opts ->
                   assert session_id == refreshed.session_id
                   assert attrs.transcript =~ "plain text caption"
                   assert opts[:caption_file] == caption_file

                   {:ok,
                    %{
                      handoff: %{handoff_id: "handoff-from-file", title: "Caption file"},
                      response: %{spoken_summary: ""}
                    }}
                 end
               )

      assert consulted.status == "consulted"

      assert [%{source: "caption", handoff: %{handoff_id: "handoff-from-file"}}] =
               consulted.events
    after
      File.rm(caption_file)
    end
  end

  test "realtime watch uses the stored egress command for speech output" do
    assert {:ok, %Session{} = session} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               title: "Stored speech command"
             })

    assert {:ok, joined} =
             GoogleMeet.join_session(session,
               runner: "browser-agent",
               join_client: fn session, _opts ->
                 {:ok,
                  %{
                    runner: "browser-agent",
                    status: "live",
                    debug_url: "iab://codex",
                    target: %{
                      "id" => "stored-egress-tab",
                      "type" => "browser-agent",
                      "url" => session.meeting_uri
                    },
                    cdp: %{"mode" => "browser-agent"},
                    joined?: true,
                    join_clicked?: true,
                    actions: []
                  }}
               end
             )

    assert {:ok, %Session{} = joined_session} = GoogleMeet.get_session(joined.session.session_id)

    speech_path = Path.join(System.tmp_dir!(), "jx-meet-speech-#{System.unique_integer()}.sh")

    speech_output_path =
      Path.join(System.tmp_dir!(), "jx-meet-spoken-#{System.unique_integer()}.txt")

    command_path = Path.join(System.tmp_dir!(), "jx-meet-consult-#{System.unique_integer()}.sh")
    Process.put(:stored_speech_path, speech_path)
    Process.put(:stored_speech_output_path, speech_output_path)
    Process.put(:stored_command_path, command_path)

    File.write!(speech_path, """
    #!/bin/sh
    cat > #{JX.Shell.quote(speech_output_path)}
    printf '%s' stored-speech-sent
    """)

    File.write!(command_path, """
    #!/bin/sh
    cat >/dev/null
    printf '%s' '{"response":"Stored egress command heard this.","summary":"Stored speech command received a Meet response."}'
    """)

    File.chmod!(speech_path, 0o700)
    File.chmod!(command_path, 0o700)

    assert {:ok, _started} =
             GoogleMeet.start_realtime(
               joined_session,
               %{
                 live: true,
                 provider: "browser-agent",
                 audio_bridge: "browser-agent",
                 audio_egress_command: speech_path,
                 approve_audio_capture: true,
                 approve_speech_output: true,
                 approve_notes_or_transcription: true
               }
             )

    assert {:ok, ready_session} = GoogleMeet.get_session(joined.session.session_id)
    assert {:ok, plan} = GoogleMeet.realtime_plan(ready_session)
    assert plan.egress.mode == "command"
    assert plan.egress.command == speech_path

    assert {:ok, watched} =
             GoogleMeet.realtime_watch(ready_session,
               caption_client: fn _session, _state ->
                 {:ok, %{"transcript" => "Please speak through the stored egress command."}}
               end,
               consult_command: command_path,
               iterations: 1,
               min_chars: 5,
               speak: true
             )

    assert [%{response: response}] = watched.events
    assert response.spoken_summary == "Stored egress command heard this."
    assert watched.watcher["last_speech"]["status"] == "sent"
    assert File.read!(speech_output_path) == "Stored egress command heard this."
  after
    if path = Process.get(:stored_speech_path), do: File.rm(path)
    if path = Process.get(:stored_speech_output_path), do: File.rm(path)
    if path = Process.get(:stored_command_path), do: File.rm(path)
  end

  test "rejects invalid Twilio connect tracks" do
    assert {:error, changeset} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               twilio_stream_url: "wss://voice.example.test/meet",
               twilio_mode: "connect",
               twilio_track: "both_tracks"
             })

    assert {"must be inbound_track for Twilio connect mode", _meta} =
             changeset.errors[:twilio_track]
  end

  test "recovers already-open Meet tabs from Chrome targets" do
    targets = [
      %{
        "id" => "target-1",
        "type" => "page",
        "title" => "Team sync",
        "url" => "https://meet.google.com/abc-mnop-xyz",
        "webSocketDebuggerUrl" => "ws://127.0.0.1:9222/devtools/page/target-1"
      },
      %{"id" => "other", "type" => "page", "url" => "https://example.com"}
    ]

    paired_targets = [
      %{
        "id" => "target-2",
        "type" => "page",
        "title" => "Team sync observer",
        "url" => "https://meet.google.com/abc-mnop-xyz",
        "webSocketDebuggerUrl" => "ws://127.0.0.1:9223/devtools/page/target-2"
      }
    ]

    assert {:ok, recovery} =
             GoogleMeet.recover_open_tabs(%{
               targets: targets,
               paired_targets: paired_targets,
               debug_url: "http://127.0.0.1:9222",
               paired_debug_url: "http://127.0.0.1:9223",
               meeting: "abc-mnop-xyz",
               dry_run: true
             })

    assert [%{meeting_code: "abc-mnop-xyz"} = candidate] = recovery.candidates
    assert candidate.primary_target["id"] == "target-1"
    assert candidate.paired_target["id"] == "target-2"
    assert recovery.created == []
  end

  test "recovery loads targets from files creates sessions and reports target load errors" do
    targets_path = Path.join(System.tmp_dir!(), "jx-meet-targets-#{System.unique_integer()}.json")

    bad_targets_path =
      Path.join(System.tmp_dir!(), "jx-meet-targets-bad-#{System.unique_integer()}.json")

    File.write!(
      targets_path,
      Jason.encode!(%{
        "targets" => [
          %{
            "id" => "target-file",
            "title" => "File target",
            "url" => "https://meet.google.com/abc-mnop-xyz"
          },
          "not-a-target"
        ]
      })
    )

    File.write!(bad_targets_path, Jason.encode!(%{"targets" => %{}}))

    try do
      assert {:ok, recovery} =
               GoogleMeet.recover_open_tabs(%{
                 targets_json: targets_path,
                 handoff: false,
                 title: "Recovered from file"
               })

      assert [%{meeting_code: "abc-mnop-xyz"}] = recovery.candidates
      assert [%{status: "recovered", title: "Recovered from file"}] = recovery.created
      assert [%Session{status: "recovered"}] = GoogleMeet.list_sessions(status: "recovered")

      assert {:error, "targets JSON must be a list" <> _} =
               GoogleMeet.recover_open_tabs(%{targets_json: bad_targets_path})

      assert {:error, "could not read targets JSON" <> _} =
               GoogleMeet.recover_open_tabs(%{targets_json: targets_path <> ".missing"})

      http_client = fn :get, "http://chrome/json/list", [], "" ->
        {:ok, %{status: 500, body: %{"error" => "offline"}}}
      end

      assert {:error, "chrome target discovery failed with 500" <> _} =
               GoogleMeet.recover_open_tabs(%{debug_url: "http://chrome"},
                 http_client: http_client
               )
    after
      File.rm(targets_path)
      File.rm(bad_targets_path)
    end
  end

  test "syncs Meet attendance and exports session artifacts" do
    assert {:ok, _profile} =
             GoogleMeet.configure_auth(%{
               profile: "personal",
               client_id: "client-123.apps.googleusercontent.com",
               redirect_uri: "http://127.0.0.1:9876/callback"
             })

    assert {:ok, _auth} = GoogleMeet.auth_url("personal")

    token_client = fn :post, "https://oauth2.googleapis.com/token", _headers, _body ->
      {:ok,
       %{
         status: 200,
         body: %{
           "access_token" => "access-token",
           "refresh_token" => "refresh-token",
           "expires_in" => 3600
         }
       }}
    end

    assert {:ok, _auth} =
             GoogleMeet.exchange_auth_code("personal", "oauth-code", http_client: token_client)

    assert {:ok, session} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               title: "Artifact call",
               conference_record: "conferenceRecords/abc",
               twilio_stream_url: "wss://voice.example.test/meet"
             })

    meet_client = fn :get, url, headers, "" ->
      assert {"authorization", "Bearer access-token"} in headers

      cond do
        String.ends_with?(url, "/v2/conferenceRecords/abc/participants") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "participants" => [
                 %{
                   "name" => "conferenceRecords/abc/participants/p1",
                   "signedinUser" => %{
                     "displayName" => "User",
                     "email" => "user@example.com"
                   }
                 }
               ]
             }
           }}

        String.ends_with?(url, "/v2/conferenceRecords/abc/participants/p1/participantSessions") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "participantSessions" => [
                 %{
                   "name" => "conferenceRecords/abc/participants/p1/participantSessions/s1",
                   "startTime" => "2026-04-27T15:00:00Z",
                   "endTime" => "2026-04-27T15:30:00Z"
                 }
               ]
             }
           }}

        String.ends_with?(url, "/v2/conferenceRecords/abc/recordings") ->
          {:ok, %{status: 200, body: %{"recordings" => [%{"name" => "recordings/r1"}]}}}

        String.ends_with?(url, "/v2/conferenceRecords/abc/transcripts") ->
          {:ok,
           %{
             status: 200,
             body: %{"transcripts" => [%{"name" => "conferenceRecords/abc/transcripts/t1"}]}
           }}

        String.ends_with?(url, "/v2/conferenceRecords/abc/transcripts/t1/entries") ->
          {:ok,
           %{
             status: 200,
             body: %{"transcriptEntries" => [%{"text" => "Decision captured"}]}
           }}

        String.ends_with?(url, "/v2/conferenceRecords/abc/smartNotes") ->
          {:ok, %{status: 200, body: %{"smartNotes" => [%{"name" => "smartNotes/n1"}]}}}
      end
    end

    assert {:ok, synced} = GoogleMeet.sync_artifacts(session.session_id, http_client: meet_client)
    assert [%{"participant" => "User", "email" => "user@example.com"}] = synced.attendance
    assert [%{"name" => "recordings/r1"}] = synced.artifacts["recordings"]

    export_dir = Path.join(System.tmp_dir!(), "meet-export-#{System.unique_integer([:positive])}")

    assert {:ok, export} =
             GoogleMeet.export_session(session.session_id, dir: export_dir, format: "all")

    assert Path.join(export_dir, "session.json") in export.files
    assert Path.join(export_dir, "handoff.md") in export.files
    assert Path.join(export_dir, "attendance.csv") in export.files
    assert Path.join(export_dir, "twilio.xml") in export.files
    assert File.read!(Path.join(export_dir, "attendance.csv")) =~ "User"
  end

  test "sync refreshes expired tokens paginates attendance and export validates formats" do
    expired_at = DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.to_iso8601()

    assert {:ok, profile} =
             GoogleMeet.configure_auth(%{
               profile: "refreshable",
               client_id: "client-123.apps.googleusercontent.com"
             })

    profile
    |> AuthProfile.changeset(%{
      status: "authenticated",
      token:
        Jason.encode!(%{
          access_token: "expired-token",
          refresh_token: "refresh-token",
          expires_at: expired_at
        })
    })
    |> Repo.update!()

    assert {:ok, session} =
             GoogleMeet.create_session(%{
               meeting: "abc-mnop-xyz",
               title: "Refresh sync",
               auth_profile: "refreshable",
               google_space: "spaces/abc"
             })

    http_client = fn
      :post, "https://oauth2.googleapis.com/token", _headers, body ->
        assert body =~ "grant_type=refresh_token"
        assert body =~ "refresh_token=refresh-token"
        {:ok, %{status: 200, body: %{"access_token" => "new-token", "expires_in" => "3600"}}}

      :get, url, headers, "" ->
        assert {"authorization", "Bearer new-token"} in headers

        cond do
          String.ends_with?(url, "/v2/spaces/abc") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "name" => "spaces/abc",
                 "activeConference" => %{"conferenceRecord" => "conferenceRecords/live"}
               }
             }}

          String.ends_with?(url, "/v2/conferenceRecords/live/participants") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "participants" => [
                   %{
                     "name" => "conferenceRecords/live/participants/p1",
                     "anonymousUser" => %{"displayName" => "Guest, One"}
                   }
                 ],
                 "nextPageToken" => "p2"
               }
             }}

          String.contains?(url, "participants?pageToken=p2") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "participants" => [
                   %{
                     "name" => "conferenceRecords/live/participants/p2",
                     "phoneUser" => %{"displayName" => "Phone User"}
                   }
                 ]
               }
             }}

          String.contains?(url, "/participantSessions") ->
            {:ok, %{status: 200, body: %{"participantSessions" => []}}}

          String.ends_with?(url, "/recordings") or String.ends_with?(url, "/transcripts") or
              String.ends_with?(url, "/smartNotes") ->
            {:ok, %{status: 503, body: %{"error" => "optional unavailable"}}}
        end
    end

    assert {:ok, synced} = GoogleMeet.sync_artifacts(session.session_id, http_client: http_client)

    assert [%{"participant" => "Guest, One"}, %{"participant" => "Phone User"}] =
             synced.attendance

    assert synced.artifacts["recordings"] == []
    assert synced.artifacts["transcripts"] == []

    assert {:ok, refreshed_profile} = GoogleMeet.get_auth_profile("refreshable")
    assert refreshed_profile.token |> Jason.decode!() |> Map.fetch!("access_token") == "new-token"

    no_token_profile =
      refreshed_profile
      |> AuthProfile.changeset(%{name: "no-token", token: "{}"})
      |> Repo.update!()

    assert {:ok, no_token_session} =
             GoogleMeet.create_session(%{
               meeting: "def-ghij-klm",
               auth_profile: no_token_profile.name,
               google_space: "spaces/missing"
             })

    assert {:error, "google auth profile no-token has no usable access token"} =
             GoogleMeet.sync_artifacts(no_token_session.session_id)

    export_dir =
      Path.join(System.tmp_dir!(), "meet-export-refresh-#{System.unique_integer([:positive])}")

    assert {:ok, export} =
             GoogleMeet.export_session(synced.session_id,
               dir: export_dir,
               format: "attendance-csv,twiml"
             )

    assert [attendance_path] = export.files
    assert File.read!(attendance_path) =~ ~s("Guest, One")

    assert {:error, "unsupported Meet export format" <> _} =
             GoogleMeet.export_session(synced.session_id, format: "pdf")
  end

  test "CLI exposes bundled plugin and session creation" do
    plugin_output =
      capture_io(fn ->
        assert :ok = CLI.run(["meet", "plugin", "--json"])
      end)

    assert %{"id" => "google_meet", "bundled" => true} = Jason.decode!(plugin_output)

    session_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "meet",
                   "session",
                   "create",
                   "--meeting",
                   "abc-mnop-xyz",
                   "--title",
                   "CLI session",
                   "--no-handoff",
                   "--json"
                 ])
      end)

    assert %{
             "sessions" => [
               %{
                 "session_id" => session_id,
                 "meeting_code" => "abc-mnop-xyz",
                 "title" => "CLI session"
               }
             ]
           } = Jason.decode!(session_output)

    script =
      Path.join(System.tmp_dir!(), "meet-browser-agent-#{System.unique_integer([:positive])}")

    File.write!(script, """
    #!/bin/sh
    cat >/dev/null
    printf '%s\\n' '{"runner":"browser-agent","status":"live","target":{"id":"cli-tab","type":"browser-agent"},"joined":true,"join_clicked":true,"actions":[{"name":"join_meet"}]}'
    """)

    File.chmod!(script, 0o755)

    join_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "meet",
                   "session",
                   "join",
                   session_id,
                   "--browser-agent-command",
                   JX.Shell.quote(script),
                   "--json"
                 ])
      end)

    assert %{
             "session" => %{"status" => "live", "chrome_target" => %{"id" => "cli-tab"}},
             "runner" => %{"runner" => "browser-agent", "joined" => true}
           } = Jason.decode!(join_output)
  end

  defp ready_realtime_session!(title) do
    assert {:ok, %Session{} = session} =
             GoogleMeet.create_session(%{meeting: "abc-mnop-xyz", title: title})

    assert {:ok, _started} =
             GoogleMeet.start_realtime(
               session,
               %{
                 live: true,
                 provider: "browser-agent",
                 audio_bridge: "command",
                 audio_ingress_command: "capture-audio",
                 audio_egress_command: "play-audio",
                 approve_audio_capture: true,
                 approve_speech_output: true,
                 approve_notes_or_transcription: true
               }
             )

    assert {:ok, ready_session} = GoogleMeet.get_session(session.session_id)
    ready_session
  end
end
