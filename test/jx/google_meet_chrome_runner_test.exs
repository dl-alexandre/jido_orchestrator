defmodule JX.GoogleMeet.ChromeRunnerTest do
  use ExUnit.Case, async: true

  alias JX.GoogleMeet.ChromeRunner
  alias JX.GoogleMeet.Session

  defmodule FakeCDP do
    def with_session(websocket_url, fun), do: fun.(%{websocket_url: websocket_url})

    def command(conn, method, _params, _opts)
        when method in ["Page.enable", "Runtime.enable", "Page.navigate"] do
      {:ok, %{}, conn}
    end

    def command(conn, "Runtime.evaluate", _params, _opts) do
      {:ok,
       %{
         "result" => %{
           "value" => %{
             "in_call" => "true",
             "join_clicked" => false,
             "actions" => [%{"name" => "join_meet", "label" => "join now"}],
             "url" => "https://meet.google.com/abc-mnop-xyz",
             "title" => "Meet",
             "body_sample" => "leave call"
           }
         }
       }, conn}
    end
  end

  test "delegates directly when a join client is injected" do
    session = meet_session()

    assert {:ok, %{runner: "fake", session_id: "gms-test"}} =
             ChromeRunner.join(session,
               join_client: fn joined_session, opts ->
                 assert joined_session.session_id == "gms-test"
                 assert opts[:marker] == :covered
                 {:ok, %{runner: "fake", session_id: joined_session.session_id}}
               end,
               marker: :covered
             )
  end

  test "drives primary and paired Chrome targets through injected CDP and HTTP clients" do
    http_client = fn :get, url, [], "" ->
      cond do
        url == "http://chrome/json/list" ->
          {:ok, %{status: 200, body: [target("primary", "ws://primary")]}}

        url == "http://paired/json/list" ->
          {:ok, %{status: 200, body: [target("paired", "ws://paired")]}}
      end
    end

    assert {:ok, result} =
             ChromeRunner.join(meet_session(paired_chrome_node: "http://paired"),
               http_client: http_client,
               cdp_client: FakeCDP,
               settle_ms: 0,
               timeout_ms: 50,
               poll_ms: 1
             )

    assert result.runner == "chrome-cdp"
    assert result.status == "live"
    assert result.joined? == true
    assert result.debug_url == "http://chrome"
    assert result.target["id"] == "primary"
    assert result.paired.target["id"] == "paired"
  end

  test "reports an undebuggable opened target" do
    http_client = fn
      :get, "http://chrome/json/list", [], "" ->
        {:ok, %{status: 200, body: []}}

      :put, "http://chrome/json/new?https%3A%2F%2Fmeet.google.com%2Fabc-mnop-xyz", [], "" ->
        {:ok, %{status: 200, body: %{"id" => "opened-without-websocket"}}}
    end

    assert {:error, "opened Meet tab but Chrome did not return a debuggable target"} =
             ChromeRunner.join(meet_session(),
               http_client: http_client,
               cdp_client: FakeCDP,
               settle_ms: 0,
               timeout_ms: 50
             )
  end

  defp target(id, websocket_url) do
    %{
      "id" => id,
      "url" => "https://meet.google.com/abc-mnop-xyz",
      "webSocketDebuggerUrl" => websocket_url
    }
  end

  defp meet_session(attrs \\ []) do
    struct!(
      Session,
      Keyword.merge(
        [
          session_id: "gms-test",
          status: "planned",
          meeting_uri: "https://meet.google.com/abc-mnop-xyz",
          meeting_code: "abc-mnop-xyz",
          auth_profile: "personal",
          chrome_node: "http://chrome",
          paired_chrome_node: "",
          twilio_mode: "none",
          twilio_track: "inbound_track",
          attendance: "[]",
          artifacts: "{}",
          recovery: "{}",
          realtime: "{}"
        ],
        attrs
      )
    )
  end
end
