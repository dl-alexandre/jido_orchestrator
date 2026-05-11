defmodule JX.Jido.Actions.WorkspaceAction do
  @moduledoc false

  def opts_schema do
    [
      opts: [
        type: :keyword_list,
        default: [],
        doc: "Workspace API options"
      ]
    ]
  end

  def call(fun, wrap_key) when is_function(fun, 0) and is_atom(wrap_key) do
    case fun.() do
      {:ok, result} -> {:ok, %{wrap_key => result}}
      {:error, reason} -> {:error, reason}
      result -> {:ok, %{wrap_key => result}}
    end
  end
end
