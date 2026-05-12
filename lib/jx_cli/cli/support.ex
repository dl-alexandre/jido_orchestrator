defmodule JX.CLI.Support do
  @moduledoc false

  def validate_options([]), do: :ok
  def validate_options(invalid), do: {:error, "invalid options: #{inspect(invalid)}"}

  def expect_no_args([], _usage), do: :ok
  def expect_no_args(_args, usage), do: {:error, "usage: #{usage}"}

  def print_json(data) do
    data
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  def print_table(headers, rows) do
    widths =
      [headers | rows]
      |> Enum.zip()
      |> Enum.map(fn column ->
        column
        |> Tuple.to_list()
        |> Enum.map(&String.length/1)
        |> Enum.max()
      end)

    print_row(headers, widths)
    Enum.each(rows, &print_row(&1, widths))
  end

  defp print_row(row, widths) do
    row
    |> Enum.zip(widths)
    |> Enum.map(fn {value, width} -> String.pad_trailing(value, width + 2) end)
    |> IO.puts()
  end
end
