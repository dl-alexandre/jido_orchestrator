defmodule JXTest.Fixtures do
  @moduledoc false

  @devide_root Path.expand("../../fixtures/jx/devide", __DIR__)

  def devide_payload(name) do
    name
    |> devide_json()
    |> Jason.decode!()
  end

  def devide_response(conn, status, name) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, devide_json(name))
  end

  def devide_json(name) do
    @devide_root
    |> Path.join(name)
    |> File.read!()
  end

  def devide_runner_payload(name) do
    name
    |> devide_runner_json()
    |> Jason.decode!()
  end

  def devide_runner_json(name) do
    @devide_root
    |> Path.join("runner_v1/#{name}")
    |> File.read!()
  end
end
