defmodule JX.Shell do
  @moduledoc false

  def quote(value) do
    value = to_string(value)
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
