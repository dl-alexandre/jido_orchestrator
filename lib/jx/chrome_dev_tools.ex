defmodule JX.ChromeDevTools do
  @moduledoc """
  Minimal Chrome DevTools Protocol client for local participant automation.

  The client intentionally covers only the small CDP surface needed by the Meet
  runner: target discovery/opening plus request/response Runtime and Page
  commands over a DevTools WebSocket.
  """

  import Bitwise

  defstruct [:socket, :transport, :next_id]

  @type t :: %__MODULE__{}

  @doc """
  Lists page targets from a Chrome remote-debugging HTTP endpoint.
  """
  def list_targets(debug_url, opts \\ []) do
    debug_url
    |> endpoint("/json/list")
    |> http_get(opts)
    |> case do
      {:ok, targets} when is_list(targets) -> {:ok, targets}
      {:ok, %{"targets" => targets}} when is_list(targets) -> {:ok, targets}
      {:ok, other} -> {:error, "Chrome target list returned #{inspect(other)}"}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Opens a new page target.
  """
  def open_target(debug_url, url, opts \\ []) do
    open_url = endpoint(debug_url, "/json/new?" <> URI.encode_www_form(url))

    result =
      case http_put(open_url, opts) do
        {:error, _reason} -> http_get(open_url, opts)
        response -> response
      end

    case result do
      {:ok, target} when is_map(target) -> {:ok, target}
      {:ok, other} -> {:error, "Chrome target open returned #{inspect(other)}"}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Runs a function with a connected CDP session.
  """
  def with_session(websocket_url, fun, opts \\ []) do
    with {:ok, session} <- connect(websocket_url, opts) do
      try do
        fun.(session)
      after
        close(session)
      end
    end
  end

  @doc """
  Sends a CDP command and waits for the matching response.
  """
  def command(%__MODULE__{} = session, method, params \\ %{}, opts \\ []) do
    id = session.next_id || 1

    payload =
      %{
        id: id,
        method: method,
        params: params || %{}
      }
      |> Jason.encode!()

    with :ok <- send_text(session, payload),
         {:ok, response} <- receive_response(session, id, Keyword.get(opts, :timeout_ms, 5_000)) do
      next_session = %{session | next_id: id + 1}

      case response do
        %{"error" => error} -> {:error, {:cdp_error, method, error}}
        %{"result" => result} -> {:ok, result, next_session}
        other -> {:ok, other, next_session}
      end
    end
  end

  defp connect(websocket_url, opts) do
    uri = URI.parse(websocket_url)
    scheme = uri.scheme || "ws"
    transport = transport_for_scheme(scheme)
    host = uri.host || "127.0.0.1"
    port = uri.port || default_port(scheme)
    timeout = Keyword.get(opts, :timeout_ms, 5_000)
    path = websocket_path(uri)

    with {:ok, socket} <-
           transport.connect(String.to_charlist(host), port, connect_options(scheme), timeout),
         :ok <- websocket_handshake(transport, socket, host, port, path, timeout) do
      {:ok, %__MODULE__{socket: socket, transport: transport, next_id: 1}}
    end
  end

  defp close(%__MODULE__{socket: nil}), do: :ok

  defp close(%__MODULE__{transport: transport, socket: socket}) do
    _ignored = transport.close(socket)
    :ok
  end

  defp websocket_handshake(transport, socket, host, port, path, timeout) do
    key = :crypto.strong_rand_bytes(16) |> Base.encode64()

    request = [
      "GET #{path} HTTP/1.1\r\n",
      "Host: #{host}:#{port}\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Key: #{key}\r\n",
      "Sec-WebSocket-Version: 13\r\n",
      "\r\n"
    ]

    with :ok <- transport.send(socket, request),
         {:ok, response} <- receive_headers(transport, socket, "", timeout) do
      if String.starts_with?(response, "HTTP/1.1 101") or
           String.starts_with?(response, "HTTP/1.0 101") do
        :ok
      else
        {:error, "Chrome WebSocket upgrade failed: #{String.split(response, "\r\n") |> hd()}"}
      end
    end
  end

  defp receive_headers(transport, socket, acc, timeout) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case transport.recv(socket, 0, timeout) do
        {:ok, data} -> receive_headers(transport, socket, acc <> data, timeout)
        {:error, reason} -> {:error, "Chrome WebSocket handshake read failed: #{inspect(reason)}"}
      end
    end
  end

  defp send_text(session, text) do
    payload = IO.iodata_to_binary(text)
    mask = :crypto.strong_rand_bytes(4)
    header = websocket_header(byte_size(payload), 0x1, true)
    masked_payload = mask_payload(payload, mask)

    session.transport.send(session.socket, [header, mask, masked_payload])
  end

  defp receive_response(session, id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_response(session, id, deadline, timeout)
  end

  defp receive_response(session, id, deadline, timeout) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, {:cdp_timeout, id, timeout}}
    else
      with {:ok, frame} <- receive_frame(session, remaining),
           {:ok, message} <- Jason.decode(frame) do
        if Map.get(message, "id") == id do
          {:ok, message}
        else
          receive_response(session, id, deadline, timeout)
        end
      else
        {:control, _opcode} -> receive_response(session, id, deadline, timeout)
        {:error, _reason} = error -> error
      end
    end
  end

  defp receive_frame(session, timeout) do
    with {:ok, <<first, second>>} <- recv_exact(session, 2, timeout),
         opcode <- Bitwise.band(first, 0x0F),
         masked? <- Bitwise.band(second, 0x80) == 0x80,
         {:ok, length} <- payload_length(session, Bitwise.band(second, 0x7F), timeout),
         {:ok, mask} <- maybe_recv_mask(session, masked?, timeout),
         {:ok, payload} <- recv_exact(session, length, timeout) do
      payload = if masked?, do: mask_payload(payload, mask), else: payload

      case opcode do
        0x1 -> {:ok, payload}
        0x8 -> {:error, :websocket_closed}
        opcode when opcode in [0x9, 0xA] -> {:control, opcode}
        opcode -> {:error, {:unsupported_websocket_frame, opcode}}
      end
    end
  end

  defp recv_exact(_session, 0, _timeout), do: {:ok, ""}

  defp recv_exact(session, length, timeout) do
    case session.transport.recv(session.socket, length, timeout) do
      {:ok, data} when byte_size(data) == length ->
        {:ok, data}

      {:ok, data} ->
        with {:ok, rest} <- recv_exact(session, length - byte_size(data), timeout) do
          {:ok, data <> rest}
        end

      {:error, reason} ->
        {:error, "Chrome WebSocket read failed: #{inspect(reason)}"}
    end
  end

  defp payload_length(_session, length, _timeout) when length < 126, do: {:ok, length}

  defp payload_length(session, 126, timeout) do
    with {:ok, <<length::16>>} <- recv_exact(session, 2, timeout), do: {:ok, length}
  end

  defp payload_length(session, 127, timeout) do
    with {:ok, <<length::64>>} <- recv_exact(session, 8, timeout), do: {:ok, length}
  end

  defp maybe_recv_mask(_session, false, _timeout), do: {:ok, <<>>}
  defp maybe_recv_mask(session, true, timeout), do: recv_exact(session, 4, timeout)

  defp websocket_header(length, opcode, masked?) when length < 126 do
    <<0x80 ||| opcode, mask_bit(masked?) ||| length>>
  end

  defp websocket_header(length, opcode, masked?) when length <= 65_535 do
    <<0x80 ||| opcode, mask_bit(masked?) ||| 126, length::16>>
  end

  defp websocket_header(length, opcode, masked?) do
    <<0x80 ||| opcode, mask_bit(masked?) ||| 127, length::64>>
  end

  defp mask_payload(payload, mask) do
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, Enum.at(mask_bytes, rem(index, 4))) end)
    |> :binary.list_to_bin()
  end

  defp mask_bit(true), do: 0x80
  defp mask_bit(false), do: 0

  defp http_get(url, opts) do
    http_request(:get, url, opts)
  end

  defp http_put(url, opts) do
    http_request(:put, url, opts)
  end

  defp http_request(method, url, opts) do
    case Keyword.get(opts, :http_client) do
      nil -> default_http_request(method, url)
      client -> client.(method, url, [], "")
    end
    |> normalize_http_response()
  end

  defp default_http_request(:get, url) do
    _inets = Application.ensure_all_started(:inets)
    _ssl = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [{:timeout, 15_000}], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:ok, %{status: status, body: decode_body(body)}}

      {:error, reason} ->
        {:error, "Chrome HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp default_http_request(method, url) do
    _inets = Application.ensure_all_started(:inets)
    _ssl = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), [], ~c"application/json", ""}

    case :httpc.request(method, request, [{:timeout, 15_000}], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:ok, %{status: status, body: decode_body(body)}}

      {:error, reason} ->
        {:error, "Chrome HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp normalize_http_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp normalize_http_response({:ok, %{status: status, body: body}}),
    do: {:error, "Chrome HTTP request failed with #{status}: #{inspect(body)}"}

  defp normalize_http_response({:error, _reason} = error), do: error

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp endpoint(debug_url, path), do: String.trim_trailing(debug_url, "/") <> path

  defp websocket_path(%URI{path: path, query: nil}), do: empty_path(path)
  defp websocket_path(%URI{path: path, query: query}), do: empty_path(path) <> "?" <> query

  defp empty_path(nil), do: "/"
  defp empty_path(""), do: "/"
  defp empty_path(path), do: path

  defp transport_for_scheme("wss"), do: :ssl
  defp transport_for_scheme(_scheme), do: :gen_tcp

  defp default_port("wss"), do: 443
  defp default_port(_scheme), do: 80

  defp connect_options("wss"), do: [:binary, active: false]
  defp connect_options(_scheme), do: [:binary, active: false, packet: :raw]
end
