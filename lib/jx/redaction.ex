defmodule JX.Redaction do
  @moduledoc """
  Redacts credential-shaped values from observable command strings.
  """

  @redacted "<redacted>"

  @env_assignment ~r/((?:^|[\s'"])(?:--?)?[A-Za-z_][A-Za-z0-9_-]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|CREDENTIAL|AUTH)[A-Za-z0-9_-]*=)(?:"[^"]*"|'[^']*'|[^\s'"]+)/i
  @flag_assignment ~r/((?:^|\s)--?[A-Za-z0-9_-]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API[-_]?KEY|ACCESS[-_]?KEY|PRIVATE[-_]?KEY|CREDENTIAL)[A-Za-z0-9_-]*=)(?:"[^"]*"|'[^']*'|[^\s'"]+)/i
  @flag_value ~r/((?:^|\s)--?[A-Za-z0-9_-]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API[-_]?KEY|ACCESS[-_]?KEY|PRIVATE[-_]?KEY|CREDENTIAL)[A-Za-z0-9_-]*)(\s+)(?:"[^"]*"|'[^']*'|[^\s'"]+)/i
  @query_param ~r/([?&][A-Za-z0-9_.-]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API[-_]?KEY|ACCESS[-_]?KEY|PRIVATE[-_]?KEY|CREDENTIAL)[A-Za-z0-9_.-]*=)[^&\s'"]+/i
  @bearer_header ~r/((?:authorization:\s*)?bearer\s+)[A-Za-z0-9._~+\/=-]+/i
  @resume_flag ~r/((?:^|\s)--resume)(\s+)[^\s'"]+/i

  def redact_command(command) when is_binary(command) do
    command
    |> replace(@env_assignment, "\\1#{@redacted}")
    |> replace(@flag_assignment, "\\1#{@redacted}")
    |> replace(@flag_value, "\\1\\2#{@redacted}")
    |> replace(@query_param, "\\1#{@redacted}")
    |> replace(@bearer_header, "\\1#{@redacted}")
    |> replace(@resume_flag, "\\1\\2#{@redacted}")
  end

  def redact_command(command), do: command

  defp replace(command, regex, replacement), do: Regex.replace(regex, command, replacement)
end
