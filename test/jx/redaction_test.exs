defmodule JX.RedactionTest do
  use ExUnit.Case, async: true

  alias JX.Redaction

  test "redact_command masks credential-shaped environment assignments" do
    command =
      "env 'OPENAI_API_KEY=sk-test' JIRA_API_TOKEN=token-value UNIFI_PASSWORD=\"secret\" MIX_ENV=test"

    redacted = Redaction.redact_command(command)

    assert redacted =~ "'OPENAI_API_KEY=<redacted>'"
    assert redacted =~ "JIRA_API_TOKEN=<redacted>"
    assert redacted =~ "UNIFI_PASSWORD=<redacted>"
    assert redacted =~ "MIX_ENV=test"
    refute redacted =~ "sk-test"
    refute redacted =~ "token-value"
    refute redacted =~ "secret"
  end

  test "redact_command masks credential flags, query params, and bearer tokens" do
    command =
      "tool --api-key sk-test --password blade-value https://example.test?access_token=abc -H 'Authorization: Bearer jwt-token'"

    redacted = Redaction.redact_command(command)

    assert redacted =~ "--api-key <redacted>"
    assert redacted =~ "--password <redacted>"
    assert redacted =~ "access_token=<redacted>"
    assert redacted =~ "Bearer <redacted>"
    refute redacted =~ "sk-test"
    refute redacted =~ "blade-value"
    refute redacted =~ "jwt-token"
  end
end
