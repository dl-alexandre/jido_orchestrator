defmodule JX.DevIDE.Client do
  @moduledoc """
  HTTP client for the narrow DevIDE workspace API used by JX.

  Configuration is intentionally owned by JX. DevIDE stays a plain HTTP
  dependency. Portfolio/status flows use `GET`; approval-gated command reruns
  use the single M30 `POST /api/workspaces/:id/runs` endpoint.
  """

  defmodule Error do
    @moduledoc "Normalized DevIDE client error."

    @type reason ::
            :unauthorized
            | :not_found
            | :unavailable
            | :http_error
            | :request_failed
            | :invalid_config

    @type t :: %__MODULE__{
            reason: reason(),
            message: String.t(),
            status: pos_integer() | nil,
            failure_class: String.t() | nil
          }

    @enforce_keys [:reason, :message]
    defstruct [:reason, :message, :status, :failure_class]
  end

  @type t :: %__MODULE__{
          base_url: String.t(),
          api_token: String.t() | nil
        }

  @enforce_keys [:base_url]
  defstruct [:base_url, :api_token]

  @default_url "http://localhost:4000"

  @doc """
  Builds a client from explicit opts or JX environment variables.

  Supported opts:
    * `:base_url` - defaults to `JX_DEVIDE_URL` or `http://localhost:4000`
    * `:api_token` - defaults to `JX_DEVIDE_API_TOKEN`
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_url =
      opts
      |> Keyword.get(:base_url)
      |> present_or_env("JX_DEVIDE_URL")
      |> present_or(@default_url)
      |> String.trim_trailing("/")

    api_token =
      opts
      |> Keyword.get(:api_token)
      |> present_or_env("JX_DEVIDE_API_TOKEN")

    %__MODULE__{base_url: base_url, api_token: api_token}
  end

  @spec workspaces(t()) :: {:ok, [map()]} | {:error, Error.t()}
  def workspaces(%__MODULE__{} = client), do: get(client, "/api/workspaces")

  @spec status(t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def status(%__MODULE__{} = client, workspace_id) when is_binary(workspace_id),
    do: get(client, "/api/workspaces/#{path_segment(workspace_id)}/status")

  @spec runs(t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def runs(%__MODULE__{} = client, workspace_id) when is_binary(workspace_id),
    do: get(client, "/api/workspaces/#{path_segment(workspace_id)}/runs")

  @spec proposals(t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def proposals(%__MODULE__{} = client, workspace_id) when is_binary(workspace_id),
    do: get(client, "/api/workspaces/#{path_segment(workspace_id)}/proposals")

  @spec audit(t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def audit(%__MODULE__{} = client, workspace_id) when is_binary(workspace_id),
    do: get(client, "/api/workspaces/#{path_segment(workspace_id)}/audit")

  @spec start_run(t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def start_run(%__MODULE__{} = client, workspace_id, command_id)
      when is_binary(workspace_id) and is_binary(command_id) do
    with {:ok, %{body: body}} <- start_run_envelope(client, workspace_id, command_id) do
      {:ok, body}
    end
  end

  @spec start_run_envelope(t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def start_run_envelope(%__MODULE__{} = client, workspace_id, command_id, opts \\ [])
      when is_binary(workspace_id) and is_binary(command_id) do
    post_envelope(
      client,
      "/api/workspaces/#{path_segment(workspace_id)}/runs",
      %{command_id: command_id},
      correlation_id: Keyword.get(opts, :correlation_id)
    )
  end

  @spec enqueue_runner_assignment_envelope(t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def enqueue_runner_assignment_envelope(
        %__MODULE__{} = client,
        workspace_id,
        command_id,
        opts \\ []
      )
      when is_binary(workspace_id) and is_binary(command_id) do
    body =
      %{
        command_id: command_id,
        execution_protocol: "jx.runner.v1",
        jx_assignment_id: Keyword.get(opts, :jx_assignment_id),
        jx_action_id: Keyword.get(opts, :jx_action_id),
        jx_safe_action_kind: Keyword.get(opts, :jx_safe_action_kind),
        runner_requirements: Keyword.get(opts, :runner_requirements)
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
      |> Map.new()

    post_envelope(
      client,
      "/api/workspaces/#{path_segment(workspace_id)}/runs",
      body,
      correlation_id: Keyword.get(opts, :correlation_id)
    )
  end

  @spec runner_assignment_replay(t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def runner_assignment_replay(%__MODULE__{} = client, assignment_id)
      when is_binary(assignment_id) do
    get(client, "/api/runner/v1/assignments/#{path_segment(assignment_id)}")
  end

  @spec format_error(Error.t()) :: String.t()
  def format_error(%Error{reason: :unauthorized, status: status}) do
    status_suffix(status, "DevIDE authorization failed. Check JX_DEVIDE_API_TOKEN.")
  end

  def format_error(%Error{reason: :unavailable, status: status, message: message}) do
    status_suffix(status, "DevIDE is unavailable: #{message}.")
  end

  def format_error(%Error{reason: :not_found, status: status}) do
    status_suffix(status, "DevIDE workspace was not found.")
  end

  def format_error(%Error{message: message, status: nil, failure_class: failure_class}),
    do: "DevIDE request failed: #{message}#{failure_suffix(failure_class)}."

  def format_error(%Error{message: message, status: status, failure_class: failure_class}),
    do:
      status_suffix(status, "DevIDE request failed: #{message}#{failure_suffix(failure_class)}.")

  defp get(%__MODULE__{} = client, path) do
    request(:get, client, path)
  end

  defp post_envelope(%__MODULE__{} = client, path, body, opts) do
    request_envelope(:post, client, path, [json: body], Keyword.get(opts, :correlation_id))
  end

  defp request(method, %__MODULE__{} = client, path, extra_opts \\ []) do
    with {:ok, %{body: body}} <- request_envelope(method, client, path, extra_opts, nil) do
      {:ok, body}
    end
  end

  defp request_envelope(method, %__MODULE__{} = client, path, extra_opts, correlation_id) do
    opts = [
      base_url: client.base_url,
      url: path,
      headers: headers(client, correlation_id),
      retry: false
    ]

    opts
    |> Keyword.merge(extra_opts)
    |> Keyword.put(:method, method)
    |> Req.request()
    |> unwrap_envelope(correlation_id)
  rescue
    e in ArgumentError ->
      {:error, %Error{reason: :invalid_config, message: Exception.message(e)}}
  end

  defp unwrap_envelope(
         {:ok, %Req.Response{status: status, body: body, headers: headers}},
         correlation_id
       )
       when status in 200..299 do
    {:ok,
     %{
       status: status,
       body: body,
       headers: response_headers(headers),
       correlation_id: normalize_correlation(correlation_id)
     }}
  end

  defp unwrap_envelope({:ok, %Req.Response{status: 401}}, _correlation_id) do
    {:error,
     %Error{
       reason: :unauthorized,
       status: 401,
       message: "unauthorized",
       failure_class: "claim_rejected"
     }}
  end

  defp unwrap_envelope({:ok, %Req.Response{status: 404}}, _correlation_id) do
    {:error,
     %Error{
       reason: :not_found,
       status: 404,
       message: "not found",
       failure_class: "enqueue_failed"
     }}
  end

  defp unwrap_envelope({:ok, %Req.Response{status: 503, body: body}}, _correlation_id) do
    {:error,
     %Error{
       reason: :unavailable,
       status: 503,
       message: response_error(body) || "service unavailable",
       failure_class: response_failure_class(body)
     }}
  end

  defp unwrap_envelope({:ok, %Req.Response{status: status, body: body}}, _correlation_id) do
    {:error,
     %Error{
       reason: :http_error,
       status: status,
       message: response_error(body) || "HTTP #{status}",
       failure_class: response_failure_class(body)
     }}
  end

  defp unwrap_envelope({:error, exception}, _correlation_id) do
    {:error,
     %Error{
       reason: :request_failed,
       message: Exception.message(exception),
       failure_class: "enqueue_failed"
     }}
  end

  defp headers(%__MODULE__{api_token: token}, correlation_id)
       when is_binary(token) and token != "" do
    [{"authorization", "Bearer " <> token} | correlation_headers(correlation_id)]
  end

  defp headers(_client, correlation_id), do: correlation_headers(correlation_id)

  defp correlation_headers(correlation_id)
       when is_binary(correlation_id) and correlation_id != "",
       do: [{"x-jx-correlation-id", correlation_id}]

  defp correlation_headers(_correlation_id), do: []

  defp response_error(%{"error" => error}) when is_binary(error), do: error
  defp response_error(_), do: nil

  defp response_failure_class(%{"failure_class" => failure_class})
       when is_binary(failure_class) and failure_class != "",
       do: failure_class

  defp response_failure_class(_), do: nil

  defp response_headers(headers) when is_list(headers) do
    Map.new(headers, fn
      {key, values} when is_list(values) -> {to_string(key), Enum.map(values, &to_string/1)}
      {key, value} -> {to_string(key), [to_string(value)]}
    end)
  end

  defp response_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {to_string(key), List.wrap(value)} end)
  end

  defp response_headers(_headers), do: %{}

  defp normalize_correlation(correlation_id) when is_binary(correlation_id), do: correlation_id
  defp normalize_correlation(_correlation_id), do: ""

  defp present_or_env(value, env_key), do: present_or(value, System.get_env(env_key))

  defp present_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp present_or(_value, fallback), do: fallback

  defp path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp status_suffix(status, message), do: "#{message} (HTTP #{status})"

  defp failure_suffix(nil), do: ""
  defp failure_suffix(""), do: ""
  defp failure_suffix(failure_class), do: " [#{failure_class}]"
end
