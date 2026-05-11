defmodule JX.ChromeDevToolsTest do
  use ExUnit.Case, async: true

  alias JX.ChromeDevTools

  defmodule FakeTransport do
    def send(socket, iodata) do
      Agent.update(socket, fn %{incoming: incoming, sent: sent} ->
        %{incoming: incoming, sent: [IO.iodata_to_binary(iodata) | sent]}
      end)
    end

    def recv(socket, length, _timeout) do
      Agent.get_and_update(socket, fn %{incoming: incoming} = state ->
        if incoming == "" do
          {{:error, :closed}, state}
        else
          size = if length == 0, do: byte_size(incoming), else: length
          <<chunk::binary-size(size), rest::binary>> = incoming
          {{:ok, chunk}, %{state | incoming: rest}}
        end
      end)
    end

    def close(_socket), do: :ok
  end

  test "normalizes Chrome target list and open responses through injected HTTP client" do
    http_client = fn
      :get, "http://chrome/json/list", [], "" ->
        {:ok, %{status: 200, body: %{"targets" => [%{"id" => "page-1"}]}}}

      :put, "http://chrome/json/new?https%3A%2F%2Fexample.test", [], "" ->
        {:error, "PUT unavailable"}

      :get, "http://chrome/json/new?https%3A%2F%2Fexample.test", [], "" ->
        {:ok, %{status: 200, body: %{"id" => "page-2", "webSocketDebuggerUrl" => "ws://cdp"}}}
    end

    assert {:ok, [%{"id" => "page-1"}]} =
             ChromeDevTools.list_targets("http://chrome/", http_client: http_client)

    assert {:ok, %{"id" => "page-2"}} =
             ChromeDevTools.open_target("http://chrome", "https://example.test",
               http_client: http_client
             )
  end

  test "reports malformed and failed Chrome HTTP responses" do
    assert {:error, "Chrome target list returned " <> _} =
             ChromeDevTools.list_targets("http://chrome",
               http_client: fn :get, _url, [], "" ->
                 {:ok, %{status: 200, body: "not targets"}}
               end
             )

    assert {:error, "Chrome HTTP request failed with 503" <> _} =
             ChromeDevTools.open_target("http://chrome", "https://example.test",
               http_client: fn _method, _url, [], "" ->
                 {:ok, %{status: 503, body: %{"error" => "starting"}}}
               end
             )
  end

  test "sends masked WebSocket text commands and waits for the matching CDP response" do
    response =
      Jason.encode!(%{
        id: 7,
        result: %{
          "value" => String.duplicate("observed-", 30)
        }
      })

    unmatched = Jason.encode!(%{id: 6, result: %{ignored: true}})
    incoming = ping_frame() <> text_frame(unmatched) <> text_frame(response)
    {:ok, socket} = Agent.start_link(fn -> %{incoming: incoming, sent: []} end)

    session = %ChromeDevTools{socket: socket, transport: FakeTransport, next_id: 7}

    assert {:ok, %{"value" => value}, next_session} =
             ChromeDevTools.command(session, "Runtime.evaluate", %{expression: "1 + 1"},
               timeout_ms: 1_000
             )

    assert value =~ "observed-"
    assert next_session.next_id == 8

    sent = Agent.get(socket, & &1.sent) |> hd()
    assert <<0x81, masked_length, _rest::binary>> = sent
    assert Bitwise.band(masked_length, 0x80) == 0x80
  end

  test "returns CDP error responses without advancing hidden state" do
    incoming =
      %{id: 1, error: %{"message" => "bad expression"}}
      |> Jason.encode!()
      |> text_frame()

    {:ok, socket} = Agent.start_link(fn -> %{incoming: incoming, sent: []} end)
    session = %ChromeDevTools{socket: socket, transport: FakeTransport, next_id: 1}

    assert {:error, {:cdp_error, "Runtime.evaluate", %{"message" => "bad expression"}}} =
             ChromeDevTools.command(session, "Runtime.evaluate", %{}, timeout_ms: 1_000)
  end

  defp text_frame(payload) when byte_size(payload) < 126 do
    <<0x81, byte_size(payload)>> <> payload
  end

  defp text_frame(payload) do
    <<0x81, 126, byte_size(payload)::16>> <> payload
  end

  defp ping_frame, do: <<0x89, 0>>
end
