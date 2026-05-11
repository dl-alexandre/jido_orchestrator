defmodule JX.DevIDE.Workspace do
  @moduledoc "Normalized JX view of a DevIDE workspace summary."

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          status: String.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :name, :status]

  @spec from_payload(map()) :: t()
  def from_payload(payload) when is_map(payload) do
    %__MODULE__{
      id: string_field(payload, "id") || "",
      name: string_field(payload, "name"),
      status: string_field(payload, "status")
    }
  end

  defp string_field(map, key) do
    case field(map, key) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
