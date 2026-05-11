defmodule JX.GoogleMeet do
  @moduledoc """
  Google Meet participant plugin domain logic.

  The Meet REST API is used for personal Google auth, spaces, attendance, and
  artifact metadata. Joining and recovering a participant remains a Chrome/CDP
  concern because Google does not expose a REST method that joins a Meet as a
  browser participant.
  """

  import Ecto.Query

  alias JX.CallHandoffs
  alias JX.GoogleMeet.AuthProfile
  alias JX.GoogleMeet.BrowserAgentRunner
  alias JX.GoogleMeet.ChromeRunner
  alias JX.GoogleMeet.Session
  alias JX.Repo
  alias JX.Shell

  @auth_profile_prefix "gma-"
  @session_prefix "met-"
  @auth_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @meet_endpoint "https://meet.googleapis.com"
  @default_profile "personal"
  @default_scopes [
    "https://www.googleapis.com/auth/meetings.space.readonly",
    "https://www.googleapis.com/auth/meetings.space.created"
  ]
  @artifact_scopes [
    "https://www.googleapis.com/auth/drive.meet.readonly"
  ]
  @export_formats ~w(all json markdown attendance-csv twiml)
  @default_realtime_provider "browser-agent"
  @realtime_providers ~w(browser-agent openai-realtime gemini-live)
  @audio_bridges ~w(browser-agent twilio command)

  @doc """
  Returns the default scopes for personal Meet access.
  """
  def default_scopes, do: @default_scopes

  @doc """
  Returns additional restricted scopes used for Drive-backed Meet artifacts.
  """
  def artifact_scopes, do: @artifact_scopes

  @doc """
  Returns accepted export format names.
  """
  def export_formats, do: @export_formats
  def realtime_providers, do: @realtime_providers
  def audio_bridges, do: @audio_bridges

  def auth_statuses, do: AuthProfile.statuses()
  def session_statuses, do: Session.statuses()
  def twilio_modes, do: Session.twilio_modes()
  def twilio_tracks, do: Session.twilio_tracks()

  @doc """
  Creates or updates a personal Google OAuth profile.
  """
  def configure_auth(attrs) do
    attrs = Map.new(attrs)
    name = attr(attrs, :profile, attr(attrs, :name, @default_profile))
    scopes = auth_scopes(attrs)

    profile_attrs = %{
      profile_id: attr(attrs, :profile_id, auth_profile_id()),
      name: name,
      email: attr(attrs, :email, ""),
      status: "configured",
      client_id: attr(attrs, :client_id, ""),
      client_secret_env: attr(attrs, :client_secret_env, "GOOGLE_OAUTH_CLIENT_SECRET"),
      redirect_uri: attr(attrs, :redirect_uri, "http://127.0.0.1:8765/oauth2/callback"),
      scopes: encode_json(scopes),
      last_error: ""
    }

    case Repo.get_by(AuthProfile, name: name) do
      nil ->
        %AuthProfile{}
        |> AuthProfile.changeset(profile_attrs)
        |> Repo.insert()

      profile ->
        profile
        |> AuthProfile.changeset(Map.delete(profile_attrs, :profile_id))
        |> Repo.update()
    end
  end

  @doc """
  Lists configured Google auth profiles.
  """
  def list_auth_profiles(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    AuthProfile
    |> order_by([profile], asc: profile.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets an auth profile by name.
  """
  def get_auth_profile(name \\ @default_profile) do
    case Repo.get_by(AuthProfile, name: blank_default(name, @default_profile)) do
      nil -> {:error, :google_meet_auth_profile_not_found}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Starts an OAuth request by storing a PKCE verifier and returning the browser URL.
  """
  def auth_url(profile_name \\ @default_profile, opts \\ []) do
    with {:ok, profile} <- get_auth_profile(profile_name) do
      scopes = Keyword.get(opts, :scopes) || decode_json_list(profile.scopes)
      state = token_bytes(18)
      verifier = token_bytes(48)
      challenge = pkce_challenge(verifier)
      redirect_uri = Keyword.get(opts, :redirect_uri, profile.redirect_uri)
      login_hint = Keyword.get(opts, :login_hint, profile.email)

      params =
        %{
          "access_type" => "offline",
          "client_id" => profile.client_id,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "include_granted_scopes" => "true",
          "prompt" => "consent",
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => Enum.join(scopes, " "),
          "state" => state
        }
        |> maybe_param("login_hint", login_hint)

      pending_auth = %{
        state: state,
        code_verifier: verifier,
        code_challenge: challenge,
        redirect_uri: redirect_uri,
        scopes: scopes,
        created_at: DateTime.utc_now()
      }

      {:ok, updated} =
        profile
        |> AuthProfile.changeset(%{
          status: "pending",
          pending_auth: encode_json(pending_auth),
          last_error: ""
        })
        |> Repo.update()

      {:ok,
       %{
         profile: auth_profile_summary(updated),
         auth_url: @auth_endpoint <> "?" <> URI.encode_query(params),
         state: state,
         scopes: scopes
       }}
    end
  end

  @doc """
  Exchanges an OAuth authorization code for a token and stores it locally.
  """
  def exchange_auth_code(profile_name \\ @default_profile, code, opts \\ []) do
    with {:ok, profile} <- get_auth_profile(profile_name),
         {:ok, pending_auth} <- pending_auth(profile),
         {:ok, token} <- exchange_code(profile, pending_auth, code, opts) do
      {:ok, updated} =
        profile
        |> AuthProfile.changeset(%{
          status: "authenticated",
          token: encode_json(token),
          pending_auth: "{}",
          last_error: "",
          authenticated_at: DateTime.utc_now()
        })
        |> Repo.update()

      {:ok, auth_profile_summary(updated)}
    else
      {:error, reason} = error ->
        _ignored = mark_auth_error(profile_name, reason)
        error
    end
  end

  @doc """
  Returns a redacted auth profile packet.
  """
  def auth_profile_summary(%AuthProfile{} = profile) do
    token = decode_json_map(profile.token)
    pending_auth = decode_json_map(profile.pending_auth)

    %{
      profile_id: profile.profile_id,
      name: profile.name,
      email: profile.email,
      status: profile.status,
      client_id: profile.client_id,
      client_secret_env: profile.client_secret_env,
      redirect_uri: profile.redirect_uri,
      scopes: decode_json_list(profile.scopes),
      token: %{
        present: map_present?(token),
        has_access_token: present?(Map.get(token, "access_token")),
        has_refresh_token: present?(Map.get(token, "refresh_token")),
        expires_at: Map.get(token, "expires_at")
      },
      pending_auth: %{
        present: map_present?(pending_auth),
        state: Map.get(pending_auth, "state"),
        created_at: Map.get(pending_auth, "created_at")
      },
      last_error: profile.last_error,
      authenticated_at: profile.authenticated_at,
      inserted_at: profile.inserted_at,
      updated_at: profile.updated_at
    }
  end

  @doc """
  Creates a durable Meet participant session.
  """
  def create_session(attrs, opts \\ []) do
    with {:ok, session_attrs} <- session_attrs(attrs),
         {:ok, session} <-
           %Session{}
           |> Session.changeset(session_attrs)
           |> Repo.insert() do
      maybe_create_handoff(session, opts)
    end
  end

  @doc """
  Lists durable Meet participant sessions.
  """
  def list_sessions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Session
    |> maybe_filter(:status, Keyword.get(opts, :status))
    |> maybe_filter(:project, Keyword.get(opts, :project))
    |> maybe_filter(:ref, Keyword.get(opts, :ref))
    |> maybe_filter(:meeting_code, Keyword.get(opts, :meeting_code))
    |> order_by([session], desc: session.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets a durable Meet participant session.
  """
  def get_session(session_id) do
    case Repo.get_by(Session, session_id: session_id) do
      nil -> {:error, :google_meet_session_not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  Returns a JSON-ready session packet.
  """
  def session_summary(%Session{} = session) do
    %{
      session_id: session.session_id,
      status: session.status,
      meeting_uri: session.meeting_uri,
      meeting_code: session.meeting_code,
      title: session.title,
      project: session.project,
      ref: session.ref,
      auth_profile: session.auth_profile,
      google_space: session.google_space,
      conference_record: session.conference_record,
      chrome_node: session.chrome_node,
      paired_chrome_node: session.paired_chrome_node,
      chrome_target: decode_json_map(session.chrome_target),
      paired_chrome_target: decode_json_map(session.paired_chrome_target),
      twilio_mode: session.twilio_mode,
      twilio_stream_url: session.twilio_stream_url,
      twilio_track: session.twilio_track,
      twilio_call_sid: session.twilio_call_sid,
      websocket_url: session.websocket_url,
      artifact_dir: artifact_dir(session),
      attendance: decode_json_list(session.attendance),
      artifacts: decode_json_map(session.artifacts),
      recovery: decode_json_map(session.recovery),
      realtime: decode_json_map(session.realtime),
      handoff_id: session.handoff_id,
      started_at: session.started_at,
      ended_at: session.ended_at,
      inserted_at: session.inserted_at,
      updated_at: session.updated_at
    }
  end

  @doc """
  Builds a Chrome/CDP, Twilio, Google API, and export plan for a session.
  """
  def join_plan(session_id) when is_binary(session_id) do
    with {:ok, session} <- get_session(session_id), do: join_plan(session)
  end

  def join_plan(%Session{} = session) do
    {:ok,
     %{
       session: session_summary(session),
       plugin: JX.ParticipantPlugins.GoogleMeet.plugin(),
       google: google_plan(session),
       chrome: chrome_plan(session),
       twilio: twilio_plan(session),
       recovery: recovery_plan(session),
       exports: export_plan(session)
     }}
  end

  @doc """
  Opens or recovers a Chrome target for a Meet session and drives the join flow.
  """
  def join_session(session_or_id, opts \\ [])

  def join_session(session_id, opts) when is_binary(session_id) do
    with {:ok, session} <- get_session(session_id), do: join_session(session, opts)
  end

  def join_session(%Session{} = session, opts) do
    with {:ok, runner} <- join_runner(opts) do
      case runner.join(session, opts) do
        {:ok, result} ->
          with {:ok, updated} <- update_session_after_join(session, result) do
            {:ok, %{session: session_summary(updated), runner: join_result_payload(result)}}
          end

        {:error, reason} = error ->
          _ignored = mark_session_join_error(session, reason)
          error
      end
    end
  end

  defp join_runner(opts) do
    case normalize_runner(Keyword.get(opts, :runner, "browser-agent")) do
      "browser-agent" -> {:ok, BrowserAgentRunner}
      "chrome-cdp" -> {:ok, ChromeRunner}
      runner -> {:error, "unsupported Meet join runner #{inspect(runner)}"}
    end
  end

  defp normalize_runner(runner) do
    runner
    |> to_string()
    |> String.trim()
    |> String.replace("_", "-")
  end

  defp update_session_after_join(%Session{} = session, result) when is_map(result) do
    now = DateTime.utc_now()
    runner_payload = join_result_payload(result)
    target = join_value(result, :target, decode_json_map(session.chrome_target))
    paired_target = paired_target(join_value(result, :paired), session)

    realtime =
      session.realtime
      |> decode_json_map()
      |> Map.merge(%{
        "join_runner" => runner_payload,
        "joined_at" => DateTime.to_iso8601(now),
        "last_error" => ""
      })
      |> Map.put(
        "chrome",
        Map.merge(Map.get(decode_json_map(session.realtime), "chrome", %{}), %{
          "runner" => runner_payload.runner,
          "node" => first_present([runner_payload.debug_url, session.chrome_node]),
          "paired_node" => session.paired_chrome_node || "",
          "target_present" => map_present?(target),
          "paired_target_present" => map_present?(paired_target)
        })
      )

    attrs = %{
      status: join_status(result),
      chrome_node: first_present([runner_payload.debug_url, session.chrome_node]),
      chrome_target: encode_json(target),
      paired_chrome_target: encode_json(paired_target),
      realtime: encode_json(realtime),
      started_at: session.started_at || now
    }

    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  defp update_session_after_join(%Session{} = session, _result) do
    session
    |> Session.changeset(%{
      status: "joining",
      started_at: session.started_at || DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp mark_session_join_error(%Session{} = session, reason) do
    realtime =
      session.realtime
      |> decode_json_map()
      |> Map.merge(%{
        "last_join_error" => inspect(reason),
        "last_join_error_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    session
    |> Session.changeset(%{status: "failed", realtime: encode_json(realtime)})
    |> Repo.update()
  end

  defp join_result_payload(result) when is_map(result) do
    %{
      runner: join_value(result, :runner, "chrome-cdp"),
      status: join_status(result),
      debug_url: join_value(result, :debug_url, ""),
      target: join_value(result, :target, %{}),
      cdp: join_value(result, :cdp, %{}),
      paired: join_value(result, :paired),
      joined: truthy?(join_value(result, :joined?, false) || join_value(result, :joined, false)),
      join_clicked:
        truthy?(
          join_value(result, :join_clicked?, false) ||
            join_value(result, :join_clicked, false) ||
            join_value(result, :joinClicked, false)
        ),
      actions: join_value(result, :actions, []),
      output: join_value(result, :output, ""),
      completed_at: join_value(result, :completed_at, DateTime.utc_now())
    }
  end

  defp join_status(result) do
    status = join_value(result, :status, "")

    cond do
      status in ["joining", "live"] -> status
      truthy?(join_value(result, :joined?, false) || join_value(result, :joined, false)) -> "live"
      true -> "joining"
    end
  end

  defp paired_target(nil, session), do: decode_json_map(session.paired_chrome_target)

  defp paired_target(paired, session) when is_map(paired) do
    case join_value(paired, :target, paired) do
      target when is_map(target) -> stringify_keys(target)
      _other -> decode_json_map(session.paired_chrome_target)
    end
  end

  defp paired_target(_paired, session), do: decode_json_map(session.paired_chrome_target)

  defp join_value(map, key, default \\ nil)

  defp join_value(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key) ||
      Map.get(map, Atom.to_string(key)) ||
      Map.get(map, key |> Atom.to_string() |> String.replace("_", "")) ||
      default
  end

  defp join_value(_map, _key, default), do: default

  @doc """
  Builds the realtime voice loop plan for a Meet session.
  """
  def realtime_plan(session_or_id, opts \\ [])

  def realtime_plan(session_id, opts) when is_binary(session_id) do
    with {:ok, session} <- get_session(session_id), do: realtime_plan(session, opts)
  end

  def realtime_plan(%Session{} = session, opts) do
    provider =
      normalize_realtime_provider(Keyword.get(opts, :provider, @default_realtime_provider))

    audio_bridge =
      normalize_audio_bridge(Keyword.get(opts, :audio_bridge, default_audio_bridge(session)))

    approvals = realtime_approvals(session, opts)
    ingress = realtime_ingress(session, audio_bridge, opts)
    egress = realtime_egress(session, audio_bridge, opts)

    {:ok,
     %{
       session: session_summary(session),
       status: realtime_plan_status(provider, ingress, egress, approvals, opts),
       provider: provider,
       audio_bridge: audio_bridge,
       consult: realtime_consult_plan(session),
       ingress: ingress,
       egress: egress,
       approvals: approvals,
       commands: realtime_commands(session),
       constraints: realtime_constraints(provider, audio_bridge, ingress, egress)
     }}
  end

  @doc """
  Persists a realtime voice-loop configuration on the Meet session.
  """
  def start_realtime(session_or_id, attrs \\ %{}, opts \\ [])

  def start_realtime(session_id, attrs, opts) when is_binary(session_id) do
    with {:ok, session} <- get_session(session_id), do: start_realtime(session, attrs, opts)
  end

  def start_realtime(%Session{} = session, attrs, opts) do
    attrs = Map.new(attrs)
    opts = Keyword.merge(Map.to_list(attrs), opts)
    live? = truthy?(attr(attrs, :live, false))

    with :ok <- validate_realtime_start_approval(live?, attrs),
         {:ok, plan} <- realtime_plan(session, opts),
         :ok <- validate_realtime_live_ready(live?, plan) do
      now = DateTime.utc_now()
      realtime = decode_json_map(session.realtime)

      voice_loop = %{
        "status" => if(live?, do: "ready", else: "planned"),
        "provider" => plan.provider,
        "audio_bridge" => plan.audio_bridge,
        "ingress" => plan.ingress,
        "egress" => plan.egress,
        "consult" => plan.consult,
        "approvals" => plan.approvals,
        "started_at" => if(live?, do: DateTime.to_iso8601(now), else: ""),
        "planned_at" => DateTime.to_iso8601(now)
      }

      {:ok, updated} =
        session
        |> Session.changeset(%{
          realtime:
            realtime
            |> Map.put("voice_loop", voice_loop)
            |> encode_json()
        })
        |> Repo.update()

      {:ok, %{session: session_summary(updated), voice_loop: voice_loop, plan: plan}}
    end
  end

  @doc """
  Records a full-agent consult handoff from a realtime Meet transcript or operator note.
  """
  def realtime_consult(session_or_id, attrs, opts \\ [])

  def realtime_consult(session_id, attrs, opts) when is_binary(session_id) do
    with {:ok, session} <- get_session(session_id), do: realtime_consult(session, attrs, opts)
  end

  def realtime_consult(%Session{} = session, attrs, opts) do
    attrs = Map.new(attrs)
    transcript = attr(attrs, :transcript, "")
    summary = first_present([attr(attrs, :summary), transcript_summary(transcript)])

    handoff_attrs = %{
      surface: "meet",
      project: first_present([attr(attrs, :project), session.project]),
      ref: first_present([attr(attrs, :ref), session.ref]),
      title: first_present([attr(attrs, :title), "Google Meet #{session.meeting_code} consult"]),
      summary: summary,
      operator_input: first_present([attr(attrs, :operator_input), transcript]),
      decisions: list_attr(attrs, :decisions, :decision),
      follow_ups: list_attr(attrs, :follow_ups, :follow_up),
      payload: %{
        plugin: "google_meet",
        google_meet_session_id: session.session_id,
        meeting_uri: session.meeting_uri,
        realtime_consult: true,
        transcript_excerpt: truncate(transcript, 1_000)
      }
    }

    with {:ok, handoff} <-
           CallHandoffs.create(handoff_attrs, brief_snapshot: Keyword.get(opts, :brief, %{})),
         {:ok, updated} <- mark_realtime_consult(session, handoff) do
      {:ok,
       %{
         session: session_summary(updated),
         handoff: CallHandoffs.handoff_summary(handoff),
         response: realtime_consult_response(session, handoff, Keyword.get(opts, :brief, %{}))
       }}
    end
  end

  @doc """
  Watches browser-agent Meet input and turns new transcript blocks into consults.

  The watch loop expects either an injected caption client, a caption/chat file,
  or a browser-agent command that can return a caption or chat snapshot. It
  intentionally deduplicates snapshots by transcript hash so repeated browser polls do not
  create duplicate handoffs.
  """
  def realtime_watch(session_or_id, opts \\ [])

  def realtime_watch(session_id, opts) when is_binary(session_id) do
    with {:ok, session} <- get_session(session_id), do: realtime_watch(session, opts)
  end

  def realtime_watch(%Session{} = session, opts) do
    with :ok <- validate_realtime_watch(session, opts) do
      state = realtime_watcher_state(session)
      iterations = normalize_watch_iterations(Keyword.get(opts, :iterations, 1))
      interval_ms = Keyword.get(opts, :interval_ms, 1_000)

      realtime_watch_loop(session, opts, iterations, interval_ms, state, [])
    end
  end

  defp validate_realtime_start_approval(false, _attrs), do: :ok

  defp validate_realtime_start_approval(true, attrs) do
    cond do
      not truthy?(attr(attrs, :approve_audio_capture, false)) ->
        {:error,
         "live Meet realtime requires --approve-audio-capture because meeting audio may be sent to the realtime provider"}

      not truthy?(attr(attrs, :approve_speech_output, false)) ->
        {:error,
         "live Meet realtime requires --approve-speech-output because synthesized speech may be transmitted into the meeting"}

      true ->
        :ok
    end
  end

  defp validate_realtime_live_ready(false, _plan), do: :ok
  defp validate_realtime_live_ready(true, %{status: "ready"}), do: :ok

  defp validate_realtime_live_ready(true, plan) do
    {:error,
     "Meet realtime loop is #{plan.status}; inspect `jx meet realtime plan` before --live"}
  end

  defp realtime_plan_status(provider, ingress, egress, approvals, opts) do
    cond do
      not realtime_provider_configured?(provider, opts) -> "needs_provider"
      not ingress.ready -> "needs_audio_ingress"
      not egress.ready -> "needs_audio_egress"
      not approvals.audio_capture or not approvals.speech_output -> "needs_approval"
      true -> "ready"
    end
  end

  defp realtime_provider_configured?("openai-realtime", opts) do
    opts
    |> Keyword.get(:openai_api_key_env, "OPENAI_API_KEY")
    |> System.get_env()
    |> present?()
  end

  defp realtime_provider_configured?("gemini-live", opts) do
    opts
    |> Keyword.get(:google_api_key_env, "GOOGLE_API_KEY")
    |> System.get_env()
    |> present?()
  end

  defp realtime_provider_configured?("browser-agent", _opts), do: true
  defp realtime_provider_configured?(_provider, _opts), do: false

  defp realtime_ingress(session, "twilio", _opts) do
    ready? = present?(session.twilio_stream_url) or present?(session.websocket_url)

    %{
      kind: "twilio-media-stream",
      ready: ready?,
      stream_url: session.twilio_stream_url,
      websocket_url: session.websocket_url,
      track: session.twilio_track
    }
  end

  defp realtime_ingress(_session, "command", opts) do
    command =
      first_present([
        Keyword.get(opts, :audio_ingress_command),
        System.get_env("JX_MEET_AUDIO_INGRESS_CMD")
      ])

    %{kind: "command", ready: present?(command), command: command}
  end

  defp realtime_ingress(session, "browser-agent", opts) do
    voice_loop = realtime_voice_loop(session)

    command =
      first_present([
        Keyword.get(opts, :audio_ingress_command),
        Keyword.get(opts, :browser_agent_command),
        get_in(voice_loop, ["ingress", "command"]),
        System.get_env("JX_MEET_BROWSER_AUDIO_IN_CMD"),
        System.get_env("JX_MEET_BROWSER_REALTIME_CMD"),
        System.get_env("JX_MEET_BROWSER_AGENT_CMD")
      ])

    target = browser_agent_target(session)

    %{
      kind: "browser-agent",
      mode: if(present?(command), do: "command", else: "active-tab"),
      ready: present?(command) or browser_agent_target_ready?(target),
      command: command,
      target: target,
      source: "meet-tab",
      requires_approval: "audio_capture"
    }
  end

  defp realtime_egress(session, "twilio", _opts) do
    ready? = session.twilio_mode == "connect" and present?(session.twilio_stream_url)

    %{
      kind: "twilio-connect-stream",
      ready: ready?,
      stream_url: session.twilio_stream_url,
      mode: session.twilio_mode
    }
  end

  defp realtime_egress(session, "command", opts) do
    voice_loop = realtime_voice_loop(session)

    command =
      first_present([
        Keyword.get(opts, :audio_egress_command),
        get_in(voice_loop, ["egress", "command"]),
        System.get_env("JX_MEET_AUDIO_EGRESS_CMD")
      ])

    %{kind: "command", ready: present?(command), command: command}
  end

  defp realtime_egress(session, "browser-agent", opts) do
    voice_loop = realtime_voice_loop(session)

    command =
      first_present([
        Keyword.get(opts, :audio_egress_command),
        Keyword.get(opts, :browser_agent_command),
        get_in(voice_loop, ["egress", "command"]),
        System.get_env("JX_MEET_BROWSER_AUDIO_OUT_CMD"),
        System.get_env("JX_MEET_BROWSER_REALTIME_CMD"),
        System.get_env("JX_MEET_BROWSER_AGENT_CMD")
      ])

    target = browser_agent_target(session)

    %{
      kind: "browser-agent",
      mode: if(present?(command), do: "command", else: "active-tab"),
      ready: present?(command) or browser_agent_target_ready?(target),
      command: command,
      target: target,
      sink: "meet-tab",
      requires_approval: "speech_output"
    }
  end

  defp realtime_consult_plan(session) do
    %{
      tool: "openclaw_agent_consult",
      local_actions: ["call_brief", "record_call_handoff"],
      command: "jx meet realtime consult #{session.session_id} --transcript <text>",
      handoff_surface: "meet"
    }
  end

  defp realtime_voice_loop(%Session{} = session) do
    session.realtime
    |> decode_json_map()
    |> Map.get("voice_loop", %{})
  end

  defp realtime_commands(session) do
    %{
      plan: "jx meet realtime plan #{session.session_id} --json",
      dry_run: "jx meet realtime start #{session.session_id} --json",
      watch: "jx meet realtime watch #{session.session_id} --iterations 0 --json",
      live:
        "jx meet realtime start #{session.session_id} --live --approve-audio-capture --approve-speech-output --approve-notes-or-transcription --json"
    }
  end

  defp realtime_constraints(provider, audio_bridge, ingress, egress) do
    [
      "Live audio capture requires explicit approval because meeting audio may be sent to #{provider}.",
      "Live speech output requires explicit approval because synthesized audio may be transmitted into the Meet.",
      audio_bridge_constraint(audio_bridge, ingress, egress)
    ]
    |> Enum.reject(&blank?/1)
  end

  defp audio_bridge_constraint("twilio", _ingress, _egress) do
    "Twilio Connect/Stream is required for bidirectional audio; Start/Stream is listen-only."
  end

  defp audio_bridge_constraint("browser-agent", ingress, egress) do
    if ingress.ready and egress.ready do
      ""
    else
      "Browser-agent realtime needs a joined browser-agent tab, JX_MEET_BROWSER_REALTIME_CMD/JX_MEET_BROWSER_AGENT_CMD, or explicit ingress/egress commands."
    end
  end

  defp audio_bridge_constraint("command", ingress, egress) do
    if ingress.ready and egress.ready,
      do: "",
      else: "Command audio bridge needs ingress and egress commands."
  end

  defp default_audio_bridge(%Session{twilio_stream_url: stream_url})
       when stream_url not in [nil, ""],
       do: "twilio"

  defp default_audio_bridge(_session), do: "browser-agent"

  defp browser_agent_target(%Session{} = session) do
    session.chrome_target
    |> decode_json_map()
    |> case do
      %{"type" => "browser-agent"} = target -> target
      _other -> %{}
    end
  end

  defp browser_agent_target_ready?(%{"type" => "browser-agent"} = target) do
    present?(Map.get(target, "id")) or present?(Map.get(target, "url"))
  end

  defp browser_agent_target_ready?(_target), do: false

  defp realtime_approvals(session, opts) do
    existing = Map.get(realtime_voice_loop(session), "approvals", %{})

    %{
      audio_capture:
        realtime_approval(opts, :approve_audio_capture, Map.get(existing, "audio_capture")),
      speech_output:
        realtime_approval(opts, :approve_speech_output, Map.get(existing, "speech_output")),
      notes_or_transcription:
        realtime_approval(
          opts,
          :approve_notes_or_transcription,
          Map.get(existing, "notes_or_transcription")
        )
    }
  end

  defp realtime_approval(opts, key, existing) do
    if Keyword.has_key?(opts, key), do: truthy?(Keyword.get(opts, key)), else: truthy?(existing)
  end

  defp normalize_realtime_provider(provider) do
    provider
    |> to_string()
    |> String.trim()
    |> String.replace("_", "-")
  end

  defp normalize_audio_bridge(bridge) do
    bridge
    |> to_string()
    |> String.trim()
    |> String.replace("_", "-")
  end

  defp mark_realtime_consult(session, handoff) do
    realtime = decode_json_map(session.realtime)
    voice_loop = Map.get(realtime, "voice_loop", %{})

    realtime =
      Map.put(
        realtime,
        "voice_loop",
        Map.merge(voice_loop, %{
          "last_consult_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "last_handoff_id" => handoff.handoff_id
        })
      )

    session
    |> Session.changeset(%{realtime: encode_json(realtime)})
    |> Repo.update()
  end

  defp realtime_consult_response(session, handoff, brief) do
    headline =
      case brief do
        %{headline: value} -> value
        %{"headline" => value} -> value
        _other -> "Consult recorded for #{session.meeting_code}"
      end

    %{
      spoken_summary: "I captured that as #{handoff.title}. #{headline}",
      handoff_id: handoff.handoff_id,
      next:
        "Use jx call handoff apply #{handoff.handoff_id} when you want this turned into an action."
    }
  end

  defp validate_realtime_watch(%Session{} = session, opts) do
    voice_loop = realtime_voice_loop(session)
    approvals = Map.get(voice_loop, "approvals", %{})

    cond do
      Map.get(voice_loop, "status") != "ready" ->
        {:error,
         "Meet realtime watch requires a ready voice loop; run `jx meet realtime start #{session.session_id} --live --approve-audio-capture --approve-speech-output --approve-notes-or-transcription` first"}

      not truthy?(Map.get(approvals, "audio_capture")) ->
        {:error,
         "Meet realtime watch requires audio/caption capture approval; rerun start with --approve-audio-capture"}

      not truthy?(Map.get(approvals, "notes_or_transcription")) ->
        {:error,
         "Meet realtime watch records caption transcripts locally; rerun start with --approve-notes-or-transcription"}

      truthy?(Keyword.get(opts, :speak, false)) and
          not truthy?(Map.get(approvals, "speech_output")) ->
        {:error,
         "Meet realtime watch speech output requires --approve-speech-output on the active voice loop"}

      true ->
        :ok
    end
  end

  defp realtime_watch_loop(session, _opts, 0, _interval_ms, state, events) do
    {:ok, realtime_watch_result(session, state, Enum.reverse(events))}
  end

  defp realtime_watch_loop(session, opts, iterations, interval_ms, state, events) do
    with {:ok, snapshot} <- realtime_caption_snapshot(session, opts, state),
         {:ok, updated_session, updated_state, event} <-
           handle_realtime_snapshot(session, snapshot, state, opts) do
      next_iterations = decrement_watch_iterations(iterations)
      next_events = [event | events]

      if next_iterations == 0 do
        {:ok, realtime_watch_result(updated_session, updated_state, Enum.reverse(next_events))}
      else
        if interval_ms > 0, do: Process.sleep(interval_ms)

        realtime_watch_loop(
          updated_session,
          opts,
          next_iterations,
          interval_ms,
          updated_state,
          next_events
        )
      end
    end
  end

  defp realtime_caption_snapshot(session, opts, state) do
    cond do
      client = Keyword.get(opts, :caption_client) ->
        invoke_caption_client(client, session, opts, state)

      chat_file = Keyword.get(opts, :chat_file) ->
        read_realtime_input_file(chat_file, "chat")

      caption_file = Keyword.get(opts, :caption_file) ->
        read_realtime_input_file(caption_file, "caption")

      command = realtime_browser_agent_command(opts) ->
        run_realtime_browser_agent_command(command, session, opts, state)

      true ->
        {:error,
         "Meet realtime watch requires --browser-agent-command, --caption-file, --chat-file, JX_MEET_BROWSER_REALTIME_CMD, or JX_MEET_BROWSER_AGENT_CMD"}
    end
  end

  defp invoke_caption_client(client, session, opts, state) when is_function(client, 3) do
    client.(session, opts, state) |> normalize_caption_client_result()
  end

  defp invoke_caption_client(client, session, _opts, state) when is_function(client, 2) do
    client.(session, state) |> normalize_caption_client_result()
  end

  defp invoke_caption_client(client, _session, _opts, _state) do
    {:error, "unsupported Meet realtime caption client #{inspect(client)}"}
  end

  defp normalize_caption_client_result({:ok, snapshot}), do: normalize_caption_snapshot(snapshot)
  defp normalize_caption_client_result({:error, _reason} = error), do: error
  defp normalize_caption_client_result(snapshot), do: normalize_caption_snapshot(snapshot)

  defp read_realtime_input_file(path, source) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, snapshot} <- decode_caption_snapshot(contents) do
          {:ok, default_realtime_snapshot_source(snapshot, source)}
        end

      {:error, reason} ->
        {:error, "could not read Meet #{source} file: #{inspect(reason)}"}
    end
  end

  defp run_realtime_browser_agent_command(command, session, opts, state) do
    payload =
      %{
        runner: "browser-agent",
        task: %{
          intent: "watch_google_meet_events",
          legacy_intent: "watch_google_meet_captions",
          channels: ["captions", "chat"],
          meeting_uri: session.meeting_uri,
          meeting_code: session.meeting_code,
          target: browser_agent_target(session),
          cursor: state
        },
        session: session_summary(session),
        options: %{
          timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
          min_chars: Keyword.get(opts, :min_chars, 12)
        }
      }

    with {:ok, payload_path} <- write_temp_payload("jx-meet-realtime", payload) do
      try do
        case System.cmd("sh", ["-lc", "#{command} < #{Shell.quote(payload_path)}"],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            decode_caption_snapshot(output)

          {output, status} ->
            {:error, "browser agent realtime exited #{status}: #{String.trim(output)}"}
        end
      after
        File.rm(payload_path)
      end
    end
  rescue
    error -> {:error, "browser agent realtime failed: #{Exception.message(error)}"}
  end

  defp decode_caption_snapshot(contents) do
    contents = String.trim(to_string(contents))

    case Jason.decode(contents) do
      {:ok, decoded} -> normalize_caption_snapshot(decoded)
      {:error, _reason} -> normalize_caption_snapshot(%{"transcript" => contents})
    end
  end

  defp normalize_caption_snapshot(snapshot) when is_list(snapshot) do
    normalize_caption_snapshot(%{"captions" => snapshot})
  end

  defp normalize_caption_snapshot(snapshot) when is_map(snapshot) do
    captions =
      normalize_realtime_entries(
        Map.get(snapshot, "captions") || Map.get(snapshot, :captions),
        "caption"
      )

    messages =
      [
        Map.get(snapshot, "messages") || Map.get(snapshot, :messages),
        Map.get(snapshot, "chat") || Map.get(snapshot, :chat)
      ]
      |> Enum.flat_map(&normalize_realtime_entries(&1, "chat"))

    entries = captions ++ messages

    source =
      first_present([
        Map.get(snapshot, "source"),
        Map.get(snapshot, :source),
        Map.get(snapshot, "input_source"),
        Map.get(snapshot, :input_source),
        infer_realtime_snapshot_source(captions, messages, snapshot)
      ])

    transcript =
      first_present([
        Map.get(snapshot, "transcript"),
        Map.get(snapshot, :transcript),
        Map.get(snapshot, "text"),
        Map.get(snapshot, :text),
        realtime_entries_to_transcript(entries)
      ])

    {:ok,
     %{
       status: Map.get(snapshot, "status") || Map.get(snapshot, :status) || "ok",
       transcript: transcript,
       captions: captions,
       messages: messages,
       entries: entries,
       source: source,
       target: Map.get(snapshot, "target") || Map.get(snapshot, :target) || %{},
       actions: Map.get(snapshot, "actions") || Map.get(snapshot, :actions) || [],
       captured_at:
         Map.get(snapshot, "captured_at") ||
           Map.get(snapshot, :captured_at) ||
           DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  defp normalize_caption_snapshot(value) do
    normalize_caption_snapshot(%{"transcript" => to_string(value)})
  end

  defp default_realtime_snapshot_source(snapshot, source) do
    Map.update(snapshot, :source, source, fn existing ->
      if blank?(existing) or existing in ["input", "transcript"], do: source, else: existing
    end)
  end

  defp normalize_realtime_entries(entries, kind) when is_list(entries) do
    entries
    |> Enum.map(&normalize_realtime_entry(&1, kind))
    |> Enum.reject(&(Map.get(&1, "text", "") |> blank?()))
  end

  defp normalize_realtime_entries(_entries, _kind), do: []

  defp normalize_realtime_entry(entry, kind) when is_map(entry) do
    %{
      "kind" =>
        first_present([
          Map.get(entry, "kind"),
          Map.get(entry, :kind),
          Map.get(entry, "source"),
          Map.get(entry, :source),
          kind
        ]),
      "speaker" =>
        first_present([
          Map.get(entry, "speaker"),
          Map.get(entry, :speaker),
          Map.get(entry, "name"),
          Map.get(entry, :name),
          Map.get(entry, "sender"),
          Map.get(entry, :sender),
          Map.get(entry, "author"),
          Map.get(entry, :author),
          Map.get(entry, "from"),
          Map.get(entry, :from)
        ]),
      "text" =>
        first_present([
          Map.get(entry, "text"),
          Map.get(entry, :text),
          Map.get(entry, "caption"),
          Map.get(entry, :caption),
          Map.get(entry, "message"),
          Map.get(entry, :message),
          Map.get(entry, "body"),
          Map.get(entry, :body),
          Map.get(entry, "content"),
          Map.get(entry, :content)
        ]),
      "at" =>
        first_present([
          Map.get(entry, "at"),
          Map.get(entry, :at),
          Map.get(entry, "timestamp"),
          Map.get(entry, :timestamp),
          Map.get(entry, "created_at"),
          Map.get(entry, :created_at)
        ])
    }
  end

  defp normalize_realtime_entry(entry, kind),
    do: %{"kind" => kind, "speaker" => "", "text" => to_string(entry), "at" => ""}

  defp infer_realtime_snapshot_source(captions, messages, snapshot) do
    cond do
      messages != [] and captions != [] -> "mixed"
      messages != [] -> "chat"
      captions != [] -> "caption"
      present?(Map.get(snapshot, "transcript") || Map.get(snapshot, :transcript)) -> "transcript"
      present?(Map.get(snapshot, "text") || Map.get(snapshot, :text)) -> "transcript"
      true -> "input"
    end
  end

  defp realtime_entries_to_transcript(entries) do
    entries
    |> Enum.map(fn entry ->
      speaker = Map.get(entry, "speaker", "")
      text = Map.get(entry, "text", "")

      if present?(speaker), do: "#{speaker}: #{text}", else: text
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp handle_realtime_snapshot(session, snapshot, state, opts) do
    transcript = snapshot.transcript |> to_string() |> String.trim()
    now = DateTime.utc_now()
    min_chars = Keyword.get(opts, :min_chars, 12)
    hash = transcript_hash(transcript)
    input_meta = realtime_snapshot_watch_fields(snapshot)

    cond do
      blank?(transcript) ->
        mark_realtime_watcher_event(
          session,
          state,
          "idle",
          now,
          Map.merge(input_meta, %{reason: "no_input_text"})
        )

      String.length(transcript) < min_chars ->
        mark_realtime_watcher_event(
          session,
          state,
          "too_short",
          now,
          Map.merge(input_meta, %{
            transcript_excerpt: transcript,
            reason: "below_min_chars"
          })
        )

      hash == Map.get(state, "last_transcript_hash") ->
        mark_realtime_watcher_event(
          session,
          state,
          "duplicate",
          now,
          Map.merge(input_meta, %{
            transcript_hash: hash,
            transcript_excerpt: truncate(transcript, 240)
          })
        )

      true ->
        consult_realtime_snapshot(session, snapshot, transcript, hash, state, opts, now)
    end
  end

  defp realtime_snapshot_watch_fields(snapshot) do
    %{
      last_input_source: Map.get(snapshot, :source, "input"),
      last_input_count: length(Map.get(snapshot, :entries, [])),
      last_caption_count: length(Map.get(snapshot, :captions, [])),
      last_message_count: length(Map.get(snapshot, :messages, []))
    }
  end

  defp consult_realtime_snapshot(session, snapshot, transcript, hash, state, opts, now) do
    attrs = %{
      transcript: transcript,
      summary: transcript_summary(transcript),
      title: "Google Meet #{session.meeting_code} realtime consult",
      operator_input: transcript,
      project: session.project,
      ref: session.ref
    }

    with {:ok, consult} <- realtime_watch_consult(session, attrs, opts),
         {:ok, refreshed} <- get_session(session.session_id),
         {:ok, speech} <- maybe_emit_realtime_speech(refreshed, consult, opts) do
      updated_state =
        state
        |> watcher_base_update("consulted", now)
        |> Map.merge(stringify_keys(realtime_snapshot_watch_fields(snapshot)))
        |> Map.merge(%{
          "last_transcript_hash" => hash,
          "last_transcript_excerpt" => truncate(transcript, 1_000),
          "last_consult_at" => DateTime.to_iso8601(now),
          "last_handoff_id" => consult.handoff.handoff_id,
          "consults_count" => Map.get(state, "consults_count", 0) + 1,
          "last_speech" => speech
        })

      with {:ok, updated_session} <- mark_realtime_watcher(refreshed, updated_state) do
        {:ok, updated_session, updated_state,
         %{
           status: "consulted",
           source: snapshot.source,
           input_count: length(snapshot.entries),
           transcript_hash: hash,
           transcript_excerpt: truncate(transcript, 240),
           captions: snapshot.captions,
           messages: snapshot.messages,
           entries: snapshot.entries,
           handoff: consult.handoff,
           response: consult.response,
           speech: speech
         }}
      end
    end
  end

  defp realtime_watch_consult(session, attrs, opts) do
    case Keyword.get(opts, :consult_fun) do
      fun when is_function(fun, 2) -> fun.(session.session_id, attrs)
      fun when is_function(fun, 3) -> fun.(session.session_id, attrs, opts)
      nil -> maybe_realtime_command_consult(session, attrs, opts)
      other -> {:error, "unsupported Meet realtime consult function #{inspect(other)}"}
    end
  end

  defp maybe_realtime_command_consult(session, attrs, opts) do
    case Keyword.get(opts, :consult_command) do
      command when is_binary(command) and command != "" ->
        run_realtime_consult_command(command, session, attrs, opts)

      nil ->
        realtime_consult(session, attrs, Keyword.drop(opts, [:caption_client, :consult_fun]))

      other ->
        {:error, "unsupported Meet realtime consult command #{inspect(other)}"}
    end
  end

  defp run_realtime_consult_command(command, session, attrs, opts) do
    payload = %{
      task: "google_meet_realtime_consult",
      session: session_summary(session),
      transcript: Map.get(attrs, :transcript, ""),
      attrs: attrs
    }

    with {:ok, payload_path} <- write_temp_payload("jx-meet-consult", payload) do
      try do
        case System.cmd("sh", ["-lc", "#{command} < #{Shell.quote(payload_path)}"],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            command_consult(session, attrs, output, opts)

          {output, status} ->
            {:error, "Meet realtime consult command exited #{status}: #{String.trim(output)}"}
        end
      after
        File.rm(payload_path)
      end
    end
  rescue
    error -> {:error, "Meet realtime consult command failed: #{Exception.message(error)}"}
  end

  defp command_consult(session, attrs, output, opts) do
    decoded = decode_command_consult_output(output)
    spoken = first_present([Map.get(decoded, "response"), Map.get(decoded, "spoken"), output])

    command_attrs =
      attrs
      |> Map.merge(%{
        summary: first_present([Map.get(decoded, "summary"), Map.get(attrs, :summary)]),
        decisions: string_list(Map.get(decoded, "decisions")) ++ Map.get(attrs, :decisions, []),
        follow_ups: string_list(Map.get(decoded, "follow_ups")) ++ Map.get(attrs, :follow_ups, [])
      })

    with {:ok, consult} <-
           realtime_consult(
             session,
             command_attrs,
             Keyword.drop(opts, [:caption_client, :consult_fun, :consult_command])
           ) do
      {:ok, put_in(consult, [:response, :spoken_summary], spoken)}
    end
  end

  defp decode_command_consult_output(output) do
    case Jason.decode(String.trim(to_string(output))) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{"response" => String.trim(to_string(output))}
    end
  end

  defp string_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp string_list(value) when is_binary(value), do: String.split(value, "\n", trim: true)
  defp string_list(nil), do: []
  defp string_list(value), do: [to_string(value)]

  defp maybe_emit_realtime_speech(_session, _consult, opts)
       when not is_list(opts) do
    {:ok, %{"status" => "skipped"}}
  end

  defp maybe_emit_realtime_speech(session, consult, opts) do
    if truthy?(Keyword.get(opts, :speak, false)) do
      text = get_in(consult, [:response, :spoken_summary]) || ""

      cond do
        blank?(text) ->
          {:ok, %{"status" => "skipped", "reason" => "empty_response"}}

        speech_client = Keyword.get(opts, :speech_client) ->
          invoke_speech_client(speech_client, text, session, consult)

        command = realtime_speech_output_command(session, opts) ->
          run_realtime_speech_command(command, text)

        true ->
          {:error,
           "Meet realtime speech output needs --speech-output-command, JX_MEET_BROWSER_SPEECH_OUT_CMD, or JX_MEET_BROWSER_AUDIO_OUT_CMD"}
      end
    else
      {:ok, %{"status" => "skipped"}}
    end
  end

  defp invoke_speech_client(client, text, session, consult) when is_function(client, 3) do
    client.(text, session, consult) |> normalize_speech_result()
  end

  defp invoke_speech_client(client, text, _session, _consult) when is_function(client, 1) do
    client.(text) |> normalize_speech_result()
  end

  defp invoke_speech_client(client, _text, _session, _consult) do
    {:error, "unsupported Meet realtime speech client #{inspect(client)}"}
  end

  defp normalize_speech_result({:ok, result}) when is_map(result),
    do: {:ok, stringify_keys(result)}

  defp normalize_speech_result({:ok, result}), do: {:ok, %{"status" => to_string(result)}}
  defp normalize_speech_result({:error, _reason} = error), do: error
  defp normalize_speech_result(result) when is_map(result), do: {:ok, stringify_keys(result)}
  defp normalize_speech_result(result), do: {:ok, %{"status" => to_string(result)}}

  defp run_realtime_speech_command(command, text) do
    input_path =
      Path.join(
        System.tmp_dir!(),
        "jx-meet-speech-#{System.unique_integer([:positive])}.txt"
      )

    with :ok <- File.write(input_path, text) do
      try do
        case System.cmd("sh", ["-lc", "#{command} < #{Shell.quote(input_path)}"],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            {:ok, %{"status" => "sent", "output" => String.trim(output)}}

          {output, status} ->
            {:error, "Meet realtime speech command exited #{status}: #{String.trim(output)}"}
        end
      after
        File.rm(input_path)
      end
    end
  rescue
    error -> {:error, "Meet realtime speech command failed: #{Exception.message(error)}"}
  end

  defp mark_realtime_watcher_event(session, state, status, now, extra) do
    updated_state =
      state
      |> watcher_base_update(status, now)
      |> Map.merge(stringify_keys(extra))

    with {:ok, updated_session} <- mark_realtime_watcher(session, updated_state) do
      {:ok, updated_session, updated_state,
       Map.merge(
         %{status: status},
         Map.take(updated_state, [
           "reason",
           "transcript_excerpt",
           "last_input_source",
           "last_input_count",
           "last_caption_count",
           "last_message_count"
         ])
       )}
    end
  end

  defp watcher_base_update(state, status, now) do
    Map.merge(state, %{
      "status" => status,
      "last_checked_at" => DateTime.to_iso8601(now),
      "iterations" => Map.get(state, "iterations", 0) + 1
    })
  end

  defp mark_realtime_watcher(session, state) do
    realtime = decode_json_map(session.realtime)
    voice_loop = Map.get(realtime, "voice_loop", %{})
    voice_loop = Map.put(voice_loop, "watcher", state)

    session
    |> Session.changeset(%{realtime: encode_json(Map.put(realtime, "voice_loop", voice_loop))})
    |> Repo.update()
  end

  defp realtime_watch_result(session, state, events) do
    %{
      session: session_summary(session),
      status: watcher_result_status(events),
      watcher: state,
      iterations: length(events),
      consulted: Enum.count(events, &(Map.get(&1, :status) == "consulted")),
      events: events
    }
  end

  defp watcher_result_status([]), do: "idle"

  defp watcher_result_status(events) do
    if Enum.any?(events, &(Map.get(&1, :status) == "consulted")), do: "consulted", else: "idle"
  end

  defp realtime_watcher_state(session) do
    session
    |> realtime_voice_loop()
    |> Map.get("watcher", %{})
  end

  defp normalize_watch_iterations(value) when value in [nil, ""], do: 1
  defp normalize_watch_iterations(0), do: :infinity

  defp normalize_watch_iterations(value) when is_integer(value) and value > 0, do: value

  defp normalize_watch_iterations(value) when is_binary(value) do
    case Integer.parse(value) do
      {0, ""} -> :infinity
      {integer, ""} when integer > 0 -> integer
      _other -> 1
    end
  end

  defp normalize_watch_iterations(_value), do: 1

  defp decrement_watch_iterations(:infinity), do: :infinity
  defp decrement_watch_iterations(value) when is_integer(value), do: value - 1

  defp transcript_hash(""), do: ""

  defp transcript_hash(transcript) do
    :crypto.hash(:sha256, transcript)
    |> Base.encode16(case: :lower)
  end

  defp realtime_browser_agent_command(opts) do
    first_present([
      Keyword.get(opts, :browser_agent_command),
      System.get_env("JX_MEET_BROWSER_REALTIME_CMD"),
      System.get_env("JX_MEET_BROWSER_AGENT_CMD")
    ])
  end

  defp realtime_speech_output_command(%Session{} = session, opts) do
    voice_loop = realtime_voice_loop(session)

    first_present([
      Keyword.get(opts, :speech_output_command),
      Keyword.get(opts, :audio_egress_command),
      get_in(voice_loop, ["egress", "command"]),
      System.get_env("JX_MEET_BROWSER_SPEECH_OUT_CMD"),
      System.get_env("JX_MEET_BROWSER_AUDIO_OUT_CMD")
    ])
  end

  defp write_temp_payload(prefix, payload) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}.json"
      )

    case File.write(path, Jason.encode!(payload)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "could not write Meet realtime payload: #{inspect(reason)}"}
    end
  end

  defp transcript_summary(""), do: ""

  defp transcript_summary(transcript) do
    transcript
    |> String.replace(~r/\s+/, " ")
    |> truncate(240)
  end

  defp list_attr(attrs, plural_key, singular_key) do
    cond do
      is_list(attr(attrs, plural_key)) ->
        attr(attrs, plural_key)

      is_binary(attr(attrs, plural_key)) ->
        String.split(attr(attrs, plural_key), "\n", trim: true)

      true ->
        list_attr_values(attrs, singular_key)
    end
  end

  defp list_attr_values(attrs, key) do
    case attr(attrs, key) do
      nil -> []
      "" -> []
      value when is_list(value) -> value
      value -> [to_string(value)]
    end
  end

  @doc """
  Generates TwiML for the session's configured Twilio Media Stream.
  """
  def twiml(%Session{twilio_stream_url: stream_url}) when stream_url in [nil, ""], do: nil

  def twiml(%Session{} = session) do
    stream_attrs =
      [
        {"name", session.session_id},
        {"url", session.twilio_stream_url}
      ]
      |> maybe_xml_attr("track", if(session.twilio_mode == "start", do: session.twilio_track))

    stream =
      [
        "<Stream#{xml_attrs(stream_attrs)}>",
        ~s(<Parameter name="plugin" value="google_meet" />),
        ~s(<Parameter name="session_id" value="#{xml_escape(session.session_id)}" />),
        ~s(<Parameter name="meeting_code" value="#{xml_escape(session.meeting_code)}" />),
        "</Stream>"
      ]
      |> Enum.join("")

    case session.twilio_mode do
      "connect" ->
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Response><Connect>#{stream}</Connect></Response>
        """
        |> String.trim()

      _start ->
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Response><Start>#{stream}</Start><Say>Google Meet participant stream connected.</Say></Response>
        """
        |> String.trim()
    end
  end

  @doc """
  Recovers already-open Meet tabs from Chrome remote debugging targets.
  """
  def recover_open_tabs(attrs, opts \\ []) do
    attrs = Map.new(attrs)

    with {:ok, primary_targets} <- load_targets(attrs, :debug_url, :targets, :targets_json, opts),
         {:ok, paired_targets} <-
           load_targets(attrs, :paired_debug_url, :paired_targets, :paired_targets_json, opts) do
      candidates = recovery_candidates(primary_targets, paired_targets, attrs)

      if truthy?(attr(attrs, :dry_run, false)) do
        {:ok, %{candidates: candidates, created: []}}
      else
        created =
          Enum.map(candidates, fn candidate ->
            candidate_attrs =
              attrs
              |> Map.merge(candidate.session_attrs)
              |> Map.put(:status, "recovered")

            case create_session(candidate_attrs, handoff: truthy?(attr(attrs, :handoff, true))) do
              {:ok, session} -> {:ok, session_summary(session)}
              {:error, reason} -> {:error, reason, candidate}
            end
          end)

        errors = Enum.filter(created, &match?({:error, _reason, _candidate}, &1))

        if errors == [] do
          {:ok, %{candidates: candidates, created: Enum.map(created, fn {:ok, item} -> item end)}}
        else
          {:error, {:google_meet_recovery_failed, errors}}
        end
      end
    end
  end

  @doc """
  Syncs attendance and artifact metadata from the Meet REST API.
  """
  def sync_artifacts(session_id, opts \\ []) do
    with {:ok, session} <- get_session(session_id),
         {:ok, profile} <- get_auth_profile(session.auth_profile),
         {:ok, access_token, _profile} <- access_token(profile, opts),
         {:ok, conference_record, space} <- resolve_conference_record(session, access_token, opts),
         {:ok, participants} <-
           meet_list_all(
             "/v2/#{conference_record}/participants",
             "participants",
             access_token,
             opts
           ),
         {:ok, attendance} <- attendance_rows(participants, access_token, opts),
         {:ok, recordings} <-
           optional_meet_list_all(
             "/v2/#{conference_record}/recordings",
             "recordings",
             access_token,
             opts
           ),
         {:ok, transcripts} <-
           optional_meet_list_all(
             "/v2/#{conference_record}/transcripts",
             "transcripts",
             access_token,
             opts
           ),
         {:ok, transcript_entries} <- transcript_entries(transcripts, access_token, opts),
         {:ok, smart_notes} <-
           optional_meet_list_all(
             "/v2/#{conference_record}/smartNotes",
             "smartNotes",
             access_token,
             opts
           ) do
      artifacts = %{
        conference_record: conference_record,
        space: space,
        participants: participants,
        recordings: recordings,
        transcripts: transcripts,
        transcript_entries: transcript_entries,
        smart_notes: smart_notes,
        synced_at: DateTime.utc_now()
      }

      {:ok, updated} =
        session
        |> Session.changeset(%{
          conference_record: conference_record,
          google_space: Map.get(space || %{}, "name", session.google_space),
          attendance: encode_json(attendance),
          artifacts: encode_json(artifacts)
        })
        |> Repo.update()

      {:ok, session_summary(updated)}
    end
  end

  @doc """
  Writes session artifacts to disk.
  """
  def export_session(session_id, opts \\ []) do
    with {:ok, session} <- get_session(session_id),
         {:ok, formats} <- normalize_export_formats(Keyword.get(opts, :format, "all")),
         :ok <- File.mkdir_p(export_dir(session, opts)) do
      dir = export_dir(session, opts)
      files = write_exports(session, formats, dir)
      {:ok, %{session: session_summary(session), dir: dir, files: files}}
    end
  end

  defp exchange_code(profile, pending_auth, code, opts) do
    form =
      %{
        "client_id" => profile.client_id,
        "code" => code,
        "code_verifier" => Map.fetch!(pending_auth, "code_verifier"),
        "grant_type" => "authorization_code",
        "redirect_uri" => Map.get(pending_auth, "redirect_uri", profile.redirect_uri)
      }
      |> maybe_param("client_secret", client_secret(profile, opts))

    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           http_request(:post, @token_endpoint, form_headers(), URI.encode_query(form), opts) do
      {:ok, token_with_expiry(body)}
    else
      {:ok, %{status: status, body: body}} ->
        {:error, "google oauth exchange failed with #{status}: #{inspect(body)}"}

      {:error, _reason} = error ->
        error
    end
  end

  defp pending_auth(profile) do
    case decode_json_map(profile.pending_auth) do
      %{"code_verifier" => verifier} = pending when is_binary(verifier) and verifier != "" ->
        {:ok, pending}

      _missing ->
        {:error, "google auth profile #{profile.name} has no pending OAuth verifier"}
    end
  end

  defp mark_auth_error(profile_name, reason) do
    with {:ok, profile} <- get_auth_profile(profile_name) do
      profile
      |> AuthProfile.changeset(%{status: "error", last_error: inspect(reason)})
      |> Repo.update()
    end
  end

  defp auth_scopes(attrs) do
    scopes =
      cond do
        is_list(attr(attrs, :scopes)) and attr(attrs, :scopes) != [] ->
          attr(attrs, :scopes)

        is_binary(attr(attrs, :scopes)) ->
          attrs
          |> attr(:scopes)
          |> String.split(~r/[\s,]+/, trim: true)

        true ->
          @default_scopes
      end

    if truthy?(attr(attrs, :artifacts, false)) do
      Enum.uniq(scopes ++ @artifact_scopes)
    else
      Enum.uniq(scopes)
    end
  end

  defp session_attrs(attrs) do
    attrs = Map.new(attrs)
    session_id = attr(attrs, :session_id, session_id())
    meeting = attr(attrs, :meeting, attr(attrs, :meeting_uri, attr(attrs, :meeting_code)))

    with {:ok, %{meeting_uri: meeting_uri, meeting_code: meeting_code}} <-
           normalize_meeting(meeting) do
      status = attr(attrs, :status, "planned")
      twilio_mode = attr(attrs, :twilio_mode, twilio_mode(attrs))
      chrome_target = attr(attrs, :chrome_target, %{})
      paired_chrome_target = attr(attrs, :paired_chrome_target, %{})

      realtime =
        attr(attrs, :realtime, %{})
        |> Map.new()
        |> Map.merge(%{
          chrome: %{
            node: attr(attrs, :chrome_node, ""),
            paired_node: attr(attrs, :paired_chrome_node, ""),
            target_present: map_present?(chrome_target),
            paired_target_present: map_present?(paired_chrome_target)
          },
          twilio: %{
            mode: twilio_mode,
            stream_url: attr(attrs, :twilio_stream_url, ""),
            track: attr(attrs, :twilio_track, "inbound_track"),
            call_sid: attr(attrs, :twilio_call_sid, ""),
            websocket_url: attr(attrs, :websocket_url, "")
          }
        })

      {:ok,
       %{
         session_id: session_id,
         status: status,
         meeting_uri: meeting_uri,
         meeting_code: meeting_code,
         title: attr(attrs, :title, ""),
         project: attr(attrs, :project, ""),
         ref: attr(attrs, :ref, ""),
         auth_profile: attr(attrs, :auth_profile, @default_profile),
         google_space: attr(attrs, :google_space, ""),
         conference_record: attr(attrs, :conference_record, ""),
         chrome_node: attr(attrs, :chrome_node, ""),
         paired_chrome_node: attr(attrs, :paired_chrome_node, ""),
         chrome_target: encode_json(chrome_target),
         paired_chrome_target: encode_json(paired_chrome_target),
         twilio_mode: twilio_mode,
         twilio_stream_url: attr(attrs, :twilio_stream_url, ""),
         twilio_track: attr(attrs, :twilio_track, "inbound_track"),
         twilio_call_sid: attr(attrs, :twilio_call_sid, ""),
         websocket_url: attr(attrs, :websocket_url, ""),
         artifact_dir: attr(attrs, :artifact_dir, default_artifact_dir(session_id)),
         attendance: encode_json(attr(attrs, :attendance, [])),
         artifacts: encode_json(attr(attrs, :artifacts, %{})),
         recovery: encode_json(attr(attrs, :recovery, %{})),
         realtime: encode_json(realtime),
         handoff_id: attr(attrs, :handoff_id, ""),
         started_at: attr(attrs, :started_at),
         ended_at: attr(attrs, :ended_at)
       }}
    end
  end

  defp twilio_mode(attrs) do
    if present?(attr(attrs, :twilio_stream_url, "")), do: "start", else: "none"
  end

  defp maybe_create_handoff(session, opts) do
    if Keyword.get(opts, :handoff, false) do
      attrs = %{
        surface: "meet",
        project: session.project,
        ref: session.ref,
        title: handoff_title(session),
        summary: handoff_summary(session),
        operator_input: "",
        decisions: [],
        follow_ups: ["export attendance and meeting artifacts when the session ends"],
        payload: %{
          plugin: "google_meet",
          google_meet_session_id: session.session_id,
          meeting_uri: session.meeting_uri,
          status: session.status
        }
      }

      with {:ok, handoff} <- CallHandoffs.create(attrs, brief_snapshot: %{}),
           {:ok, updated} <-
             session
             |> Session.changeset(%{handoff_id: handoff.handoff_id})
             |> Repo.update() do
        {:ok, updated}
      end
    else
      {:ok, session}
    end
  end

  defp handoff_title(%Session{title: title}) when title not in [nil, ""], do: title
  defp handoff_title(session), do: "Google Meet #{session.meeting_code}"

  defp handoff_summary(session) do
    "Google Meet participant session #{session.session_id} #{session.status} for #{session.meeting_uri}"
  end

  defp google_plan(session) do
    record = first_present([session.conference_record, "conferenceRecords/<active-conference>"])

    %{
      join_method: "browser-agent",
      fallback_join_method: "chrome-cdp",
      rest_join_supported: false,
      auth_profile: session.auth_profile,
      space_lookup: "/v2/spaces/#{session.meeting_code}",
      conference_record: session.conference_record,
      artifact_endpoints: %{
        participants: "/v2/#{record}/participants",
        recordings: "/v2/#{record}/recordings",
        transcripts: "/v2/#{record}/transcripts",
        smart_notes: "/v2/#{record}/smartNotes"
      }
    }
  end

  defp chrome_plan(session) do
    %{
      primary: %{
        node: blank_default(session.chrome_node, "http://127.0.0.1:9222"),
        role: "participant",
        launch_command: chrome_launch_command(session, :primary),
        target: decode_json_map(session.chrome_target)
      },
      paired: %{
        enabled:
          present?(session.paired_chrome_node) or
            map_present?(decode_json_map(session.paired_chrome_target)),
        node: session.paired_chrome_node,
        role: "paired-observer",
        launch_command: chrome_launch_command(session, :paired),
        target: decode_json_map(session.paired_chrome_target)
      }
    }
  end

  defp chrome_launch_command(session, :primary) do
    port = debug_port(session.chrome_node, 9222)

    [
      chrome_binary(),
      "--remote-debugging-port=#{port}",
      "--user-data-dir=#{shell_quote(Path.join(artifact_dir(session), "chrome-profile"))}",
      shell_quote(session.meeting_uri)
    ]
    |> Enum.join(" ")
  end

  defp chrome_launch_command(session, :paired) do
    if present?(session.paired_chrome_node) do
      port = debug_port(session.paired_chrome_node, 9223)

      [
        chrome_binary(),
        "--remote-debugging-port=#{port}",
        "--user-data-dir=#{shell_quote(Path.join(artifact_dir(session), "paired-chrome-profile"))}",
        shell_quote(session.meeting_uri)
      ]
      |> Enum.join(" ")
    else
      ""
    end
  end

  defp twilio_plan(session) do
    %{
      mode: session.twilio_mode,
      stream_url: session.twilio_stream_url,
      track: session.twilio_track,
      call_sid: session.twilio_call_sid,
      websocket_url: session.websocket_url,
      twiml: twiml(session),
      constraints: twilio_constraints(session)
    }
  end

  defp twilio_constraints(%Session{twilio_mode: "connect"}) do
    ["bidirectional Connect/Stream can receive only inbound_track and blocks following TwiML"]
  end

  defp twilio_constraints(%Session{twilio_mode: "start"}) do
    [
      "Start/Stream is unidirectional; keep another TwiML verb after Stream so the call stays alive"
    ]
  end

  defp twilio_constraints(_session), do: []

  defp recovery_plan(session) do
    %{
      command:
        "jx meet recover --debug-url #{blank_default(session.chrome_node, "http://127.0.0.1:9222")} --meeting #{session.meeting_code}",
      paired_command:
        if(present?(session.paired_chrome_node),
          do:
            "jx meet recover --debug-url #{session.chrome_node} --paired-debug-url #{session.paired_chrome_node} --meeting #{session.meeting_code}",
          else: ""
        ),
      target: decode_json_map(session.chrome_target),
      paired_target: decode_json_map(session.paired_chrome_target)
    }
  end

  defp export_plan(session) do
    %{
      artifact_dir: artifact_dir(session),
      formats: @export_formats,
      command: "jx meet export #{session.session_id} --dir #{shell_quote(artifact_dir(session))}"
    }
  end

  defp recovery_candidates(primary_targets, paired_targets, attrs) do
    meeting_filter =
      attrs
      |> attr(:meeting)
      |> case do
        nil -> nil
        meeting -> normalize_meeting(meeting)
      end

    filter_code =
      case meeting_filter do
        {:ok, %{meeting_code: code}} -> code
        _other -> nil
      end

    primary = meet_targets(primary_targets, filter_code)

    paired_by_code =
      paired_targets |> meet_targets(filter_code) |> Map.new(&{&1.meeting_code, &1})

    primary
    |> Enum.map(fn target ->
      paired = Map.get(paired_by_code, target.meeting_code)
      recovery = recovery_payload(target, paired, attrs)

      %{
        meeting_uri: target.meeting_uri,
        meeting_code: target.meeting_code,
        title: target.title,
        primary_target: target.raw,
        paired_target: if(paired, do: paired.raw, else: %{}),
        session_attrs: %{
          meeting: target.meeting_uri,
          title: first_present([attr(attrs, :title), target.title]),
          chrome_node: attr(attrs, :debug_url, attr(attrs, :chrome_node, "")),
          paired_chrome_node:
            attr(attrs, :paired_debug_url, attr(attrs, :paired_chrome_node, "")),
          chrome_target: target.raw,
          paired_chrome_target: if(paired, do: paired.raw, else: %{}),
          recovery: recovery
        }
      }
    end)
  end

  defp meet_targets(targets, filter_code) do
    targets
    |> Enum.map(&target_candidate/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn target -> is_nil(filter_code) or target.meeting_code == filter_code end)
  end

  defp target_candidate(target) when is_map(target) do
    url = Map.get(target, "url") || Map.get(target, :url) || ""

    case normalize_meeting(url) do
      {:ok, meeting} ->
        %{
          meeting_uri: meeting.meeting_uri,
          meeting_code: meeting.meeting_code,
          title: Map.get(target, "title") || Map.get(target, :title) || "",
          raw: stringify_keys(target)
        }

      {:error, _reason} ->
        nil
    end
  end

  defp target_candidate(_target), do: nil

  defp recovery_payload(target, paired, attrs) do
    %{
      recovered_at: DateTime.utc_now(),
      source: "chrome-remote-debugging",
      debug_url: attr(attrs, :debug_url, ""),
      paired_debug_url: attr(attrs, :paired_debug_url, ""),
      primary_target_id: Map.get(target.raw, "id", ""),
      paired_target_id: if(paired, do: Map.get(paired.raw, "id", ""), else: "")
    }
  end

  defp load_targets(attrs, debug_key, targets_key, file_key, opts) do
    cond do
      is_list(attr(attrs, targets_key)) ->
        {:ok, attr(attrs, targets_key)}

      present?(attr(attrs, file_key, "")) ->
        attrs
        |> attr(file_key)
        |> File.read()
        |> case do
          {:ok, contents} -> decode_targets(contents)
          {:error, reason} -> {:error, "could not read targets JSON: #{inspect(reason)}"}
        end

      present?(attr(attrs, debug_key, "")) ->
        fetch_chrome_targets(attr(attrs, debug_key), opts)

      true ->
        {:ok, []}
    end
  end

  defp decode_targets(contents) do
    case Jason.decode(contents) do
      {:ok, targets} when is_list(targets) -> {:ok, targets}
      {:ok, %{"targets" => targets}} when is_list(targets) -> {:ok, targets}
      {:ok, other} -> {:error, "targets JSON must be a list, got #{inspect(other)}"}
      {:error, reason} -> {:error, "invalid targets JSON: #{Exception.message(reason)}"}
    end
  end

  defp fetch_chrome_targets(debug_url, opts) do
    url =
      debug_url
      |> String.trim_trailing("/")
      |> Kernel.<>("/json/list")

    case http_request(:get, url, [], "", opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_list(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "chrome target discovery failed with #{status}: #{inspect(body)}"}

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_conference_record(%Session{conference_record: record}, _access_token, _opts)
       when record not in [nil, ""] do
    {:ok, record, %{}}
  end

  defp resolve_conference_record(session, access_token, opts) do
    space = first_present([session.google_space, "spaces/#{session.meeting_code}"])

    case meet_get("/v2/#{space}", access_token, opts) do
      {:ok, space_body} ->
        case get_in(space_body, ["activeConference", "conferenceRecord"]) do
          record when is_binary(record) and record != "" -> {:ok, record, space_body}
          _missing -> {:error, "meeting space #{space} has no active conference record"}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp attendance_rows(participants, access_token, opts) do
    participants
    |> Enum.reduce_while({:ok, []}, fn participant, {:ok, rows} ->
      participant_name = Map.get(participant, "name", "")

      with {:ok, sessions} <-
             meet_list_all(
               "/v2/#{participant_name}/participantSessions",
               "participantSessions",
               access_token,
               opts
             ) do
        participant_rows =
          sessions
          |> case do
            [] -> [%{}]
            sessions -> sessions
          end
          |> Enum.map(&attendance_row(participant, &1))

        {:cont, {:ok, rows ++ participant_rows}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp attendance_row(participant, session) do
    %{
      participant: display_name(participant),
      participant_name: Map.get(participant, "name", ""),
      email: participant_email(participant),
      session_name: Map.get(session, "name", ""),
      start_time: Map.get(session, "startTime", ""),
      end_time: Map.get(session, "endTime", "")
    }
  end

  defp display_name(participant) do
    first_present([
      get_in(participant, ["signedinUser", "displayName"]),
      get_in(participant, ["anonymousUser", "displayName"]),
      get_in(participant, ["phoneUser", "displayName"]),
      Map.get(participant, "displayName"),
      Map.get(participant, "name")
    ])
  end

  defp participant_email(participant) do
    first_present([
      get_in(participant, ["signedinUser", "email"]),
      Map.get(participant, "email")
    ])
  end

  defp transcript_entries(transcripts, access_token, opts) do
    transcripts
    |> Enum.reduce_while({:ok, []}, fn transcript, {:ok, entries} ->
      transcript_name = Map.get(transcript, "name", "")

      with {:ok, transcript_entries} <-
             optional_meet_list_all(
               "/v2/#{transcript_name}/entries",
               "transcriptEntries",
               access_token,
               opts
             ) do
        {:cont, {:ok, entries ++ [%{transcript: transcript_name, entries: transcript_entries}]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp access_token(profile, opts) do
    token = decode_json_map(profile.token)

    cond do
      present?(Map.get(token, "access_token")) and not token_expired?(token) ->
        {:ok, Map.fetch!(token, "access_token"), profile}

      present?(Map.get(token, "refresh_token")) ->
        refresh_token(profile, Map.fetch!(token, "refresh_token"), token, opts)

      true ->
        {:error, "google auth profile #{profile.name} has no usable access token"}
    end
  end

  defp refresh_token(profile, refresh_token, previous_token, opts) do
    form =
      %{
        "client_id" => profile.client_id,
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token
      }
      |> maybe_param("client_secret", client_secret(profile, opts))

    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           http_request(:post, @token_endpoint, form_headers(), URI.encode_query(form), opts) do
      token =
        previous_token
        |> Map.merge(body)
        |> Map.put("refresh_token", refresh_token)
        |> token_with_expiry()

      {:ok, updated} =
        profile
        |> AuthProfile.changeset(%{status: "authenticated", token: encode_json(token)})
        |> Repo.update()

      {:ok, Map.fetch!(token, "access_token"), updated}
    else
      {:ok, %{status: status, body: body}} ->
        {:error, "google oauth refresh failed with #{status}: #{inspect(body)}"}

      {:error, _reason} = error ->
        error
    end
  end

  defp token_expired?(%{"expires_at" => expires_at}) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expires_at, _offset} ->
        DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), 60, :second)) != :gt

      _invalid ->
        true
    end
  end

  defp token_expired?(_token), do: false

  defp meet_get(path, access_token, opts) do
    case http_request(:get, @meet_endpoint <> path, auth_headers(access_token), "", opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "meet API failed with #{status}: #{inspect(body)}"}

      {:error, _reason} = error ->
        error
    end
  end

  defp meet_list_all(path, key, access_token, opts) do
    meet_list_all(path, key, access_token, opts, nil, [])
  end

  defp meet_list_all(path, key, access_token, opts, page_token, acc) do
    path = append_page_token(path, page_token)

    with {:ok, body} <- meet_get(path, access_token, opts) do
      items = Map.get(body, key, [])

      case Map.get(body, "nextPageToken") do
        token when is_binary(token) and token != "" ->
          meet_list_all(path_without_query(path), key, access_token, opts, token, acc ++ items)

        _done ->
          {:ok, acc ++ items}
      end
    end
  end

  defp optional_meet_list_all(path, key, access_token, opts) do
    case meet_list_all(path, key, access_token, opts) do
      {:ok, items} -> {:ok, items}
      {:error, _reason} -> {:ok, []}
    end
  end

  defp append_page_token(path, nil), do: path

  defp append_page_token(path, page_token) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> URI.encode_query(%{"pageToken" => page_token})
  end

  defp path_without_query(path) do
    path
    |> String.split("?", parts: 2)
    |> hd()
  end

  defp normalize_export_formats("all"), do: {:ok, ["json", "markdown", "attendance-csv", "twiml"]}

  defp normalize_export_formats(format) when is_binary(format) do
    formats = String.split(format, ",", trim: true)

    if Enum.all?(formats, &(&1 in @export_formats)) do
      {:ok, formats -- ["all"]}
    else
      {:error,
       "unsupported Meet export format #{inspect(format)}; expected #{Enum.join(@export_formats, ", ")}"}
    end
  end

  defp write_exports(session, formats, dir) do
    formats
    |> Enum.flat_map(fn
      "json" ->
        [write_export(Path.join(dir, "session.json"), session_json(session))]

      "markdown" ->
        [write_export(Path.join(dir, "handoff.md"), session_markdown(session))]

      "attendance-csv" ->
        [write_export(Path.join(dir, "attendance.csv"), attendance_csv(session))]

      "twiml" ->
        maybe_twiml_export(session, dir)
    end)
  end

  defp maybe_twiml_export(session, dir) do
    case twiml(session) do
      nil -> []
      xml -> [write_export(Path.join(dir, "twilio.xml"), xml)]
    end
  end

  defp write_export(path, contents) do
    :ok = File.write(path, contents)
    path
  end

  defp session_json(session) do
    session
    |> session_summary()
    |> Jason.encode!(pretty: true)
  end

  defp session_markdown(session) do
    summary = session_summary(session)

    """
    # #{first_present([session.title, "Google Meet #{session.meeting_code}"])}

    - Session: #{session.session_id}
    - Status: #{session.status}
    - Meeting: #{session.meeting_uri}
    - Project: #{session.project}
    - Ref: #{session.ref}
    - Auth profile: #{session.auth_profile}
    - Handoff: #{session.handoff_id}

    ## Recovery

    ```json
    #{Jason.encode!(summary.recovery, pretty: true)}
    ```

    ## Artifacts

    ```json
    #{Jason.encode!(summary.artifacts, pretty: true)}
    ```
    """
  end

  defp attendance_csv(session) do
    rows = decode_json_list(session.attendance)
    header = ~w(participant email session_name start_time end_time)

    ([header] ++ Enum.map(rows, &attendance_csv_row/1))
    |> Enum.map(&csv_line/1)
    |> Enum.join("")
  end

  defp attendance_csv_row(row) do
    [
      Map.get(row, "participant") || Map.get(row, :participant) || "",
      Map.get(row, "email") || Map.get(row, :email) || "",
      Map.get(row, "session_name") || Map.get(row, :session_name) || "",
      Map.get(row, "start_time") || Map.get(row, :start_time) || "",
      Map.get(row, "end_time") || Map.get(row, :end_time) || ""
    ]
  end

  defp csv_line(fields) do
    fields
    |> Enum.map(&csv_escape/1)
    |> Enum.join(",")
    |> Kernel.<>("\n")
  end

  defp csv_escape(value) do
    value = to_string(value || "")

    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp export_dir(session, opts), do: Keyword.get(opts, :dir) || artifact_dir(session)
  defp artifact_dir(%Session{artifact_dir: dir}) when dir not in [nil, ""], do: Path.expand(dir)
  defp artifact_dir(session), do: default_artifact_dir(session.session_id)

  defp default_artifact_dir(session_id) do
    Path.expand("~/.jx/meet/#{session_id}/artifacts")
  end

  @doc """
  Normalizes a Meet URL or meeting code into a canonical URI and code.
  """
  def normalize_meeting(nil),
    do: {:error, "Google Meet session requires --meeting <url-or-code>"}

  def normalize_meeting(""), do: {:error, "Google Meet session requires --meeting <url-or-code>"}

  def normalize_meeting(value) do
    value = value |> to_string() |> String.trim()

    cond do
      Regex.match?(~r/^[a-z]+-[a-z]+-[a-z]+$/, value) ->
        {:ok, %{meeting_uri: "https://meet.google.com/#{value}", meeting_code: value}}

      true ->
        normalize_meeting_uri(value)
    end
  end

  defp normalize_meeting_uri(value) do
    uri = URI.parse(value)
    code = meeting_code_from_path(uri.path || "")

    if uri.host == "meet.google.com" and present?(code) do
      {:ok, %{meeting_uri: "https://meet.google.com/#{code}", meeting_code: code}}
    else
      {:error, "invalid Google Meet URL or code: #{inspect(value)}"}
    end
  end

  defp meeting_code_from_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.find("", &Regex.match?(~r/^[a-z]+-[a-z]+-[a-z]+$/, &1))
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, :status, value), do: where(query, [session], session.status == ^value)

  defp maybe_filter(query, :project, value),
    do: where(query, [session], session.project == ^value)

  defp maybe_filter(query, :ref, value), do: where(query, [session], session.ref == ^value)

  defp maybe_filter(query, :meeting_code, value),
    do: where(query, [session], session.meeting_code == ^value)

  defp auth_headers(access_token), do: [{"authorization", "Bearer #{access_token}"}]
  defp form_headers, do: [{"content-type", "application/x-www-form-urlencoded"}]

  defp http_request(method, url, headers, body, opts) do
    case Keyword.get(opts, :http_client) do
      nil -> default_http_request(method, url, headers, body)
      client -> client.(method, url, headers, body)
    end
  end

  defp default_http_request(method, url, headers, body) do
    opts =
      [method: method, url: url, headers: headers, retry: false]
      |> maybe_body(method, body)

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, headers: response_headers, body: response_body}} ->
        {:ok, %{status: status, headers: response_headers, body: decode_http_body(response_body)}}

      {:error, reason} ->
        {:error, "http request failed: #{Exception.message(reason)}"}
    end
  rescue
    error -> {:error, "http request failed: #{Exception.message(error)}"}
  end

  defp maybe_body(opts, :post, body), do: Keyword.put(opts, :body, body)
  defp maybe_body(opts, _method, _body), do: opts

  defp decode_http_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_http_body(body), do: body

  defp token_with_expiry(token) do
    token = stringify_keys(token)

    case Map.get(token, "expires_in") do
      seconds when is_integer(seconds) ->
        Map.put(
          token,
          "expires_at",
          DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
        )

      seconds when is_binary(seconds) ->
        case Integer.parse(seconds) do
          {seconds, ""} ->
            Map.put(
              token,
              "expires_at",
              DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
            )

          _invalid ->
            token
        end

      _missing ->
        token
    end
  end

  defp client_secret(profile, opts) do
    Keyword.get(opts, :client_secret) || System.get_env(profile.client_secret_env || "")
  end

  defp debug_port(node, default) do
    case URI.parse(to_string(node || "")) do
      %URI{port: port} when is_integer(port) -> port
      _other -> default
    end
  end

  defp chrome_binary do
    System.get_env("JX_CHROME_BIN") || "google-chrome"
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp maybe_param(map, _key, nil), do: map
  defp maybe_param(map, _key, ""), do: map
  defp maybe_param(map, key, value), do: Map.put(map, key, value)

  defp maybe_xml_attr(attrs, _key, nil), do: attrs
  defp maybe_xml_attr(attrs, _key, ""), do: attrs
  defp maybe_xml_attr(attrs, key, value), do: attrs ++ [{key, value}]

  defp xml_attrs(attrs) do
    Enum.map_join(attrs, "", fn {key, value} ->
      ~s( #{key}="#{xml_escape(value)}")
    end)
  end

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp pkce_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  defp token_bytes(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp auth_profile_id, do: @auth_profile_prefix <> random_id()
  defp session_id, do: @session_prefix <> random_id()

  defp random_id do
    5
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key)) || default
  end

  defp encode_json(value) when is_binary(value), do: value
  defp encode_json(value), do: Jason.encode!(value)

  defp decode_json_map(value) when value in [nil, ""], do: %{}

  defp decode_json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _other -> %{}
    end
  end

  defp decode_json_map(value) when is_map(value), do: stringify_keys(value)
  defp decode_json_map(_value), do: %{}

  defp decode_json_list(value) when value in [nil, ""], do: []

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _other -> []
    end
  end

  defp decode_json_list(value) when is_list(value), do: value
  defp decode_json_list(_value), do: []

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp map_present?(value) when is_map(value), do: map_size(value) > 0
  defp map_present?(_value), do: false

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp blank_default(value, default) when value in [nil, ""], do: default
  defp blank_default(value, _default), do: value

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp truncate(value, max_length) do
    value = to_string(value || "")

    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 3) <> "..."
    else
      value
    end
  end
end
