defmodule CleatDeployWeb.Api.LogError do
  @moduledoc false

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  def render(conn, {:invalid, message}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_request", message: message})
  end

  def render(conn, {:runtime, message}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "runtime_logs_failed", message: message})
  end
end
