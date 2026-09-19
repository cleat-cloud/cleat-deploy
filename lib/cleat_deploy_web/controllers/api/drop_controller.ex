defmodule CleatDeployWeb.Api.DropController do
  @moduledoc """
  Git-less deploys ("drops"): the client uploads a gzipped tarball of a static
  site and the panel publishes it on the app's server.
  """

  use CleatDeployWeb, :controller

  alias CleatDeploy.{Apps, Deployments}
  alias CleatDeployWeb.Api.Serializer

  @default_max_bytes 52_428_800
  @chunk 8_000_000

  def create(conn, %{"app_id" => app_id} = params) do
    scope = conn.assigns.current_scope
    max = max_bytes()

    with {:ok, app} <- resolve_app(scope, app_id),
         :ok <- ensure_static(app),
         {:ok, path} <- save_body(conn, max),
         {:ok, deployment, _job} <-
           Deployments.enqueue_drop(scope, app, %{
             artifact_path: path,
             git_ref: params["ref"]
           }) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.deployment(deployment)})
    else
      :error ->
        not_found(conn)

      {:error, :not_static} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "drops_require_static_runtime"})

      {:error, :too_large} ->
        conn
        |> put_status(413)
        |> json(%{error: "drop_too_large", max_bytes: max})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: to_string(reason)})
    end
  end

  defp ensure_static(%Apps.App{runtime: "static"}), do: :ok
  defp ensure_static(_app), do: {:error, :not_static}

  defp save_body(conn, max) do
    dir = drops_dir()
    File.mkdir_p!(dir)
    path = unique_path(dir)
    io = File.open!(path, [:write, :binary, :raw])

    case stream_body(conn, io, 0, max) do
      :ok ->
        File.close(io)
        {:ok, path}

      {:error, reason} ->
        File.close(io)
        File.rm(path)
        {:error, reason}
    end
  end

  defp stream_body(conn, io, size, max) do
    case Plug.Conn.read_body(conn, length: @chunk, read_length: @chunk) do
      {:ok, data, _conn} ->
        write_chunk(io, data, size, max)

      {:more, data, conn} ->
        case write_chunk(io, data, size, max) do
          :ok -> stream_body(conn, io, size + byte_size(data), max)
          error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_chunk(_io, data, size, max) when size + byte_size(data) > max,
    do: {:error, :too_large}

  defp write_chunk(io, data, _size, _max) do
    case IO.binwrite(io, data) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp unique_path(dir) do
    Path.join(
      dir,
      "drop_#{System.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}.tar.gz"
    )
  end

  defp drops_dir do
    System.get_env("CLEAT_DROPS_DIR") ||
      Application.get_env(:cleat_deploy, :drops_dir, Path.join(System.tmp_dir!(), "cleat_drops"))
  end

  defp max_bytes do
    case System.get_env("CLEAT_DROP_MAX_BYTES") do
      nil ->
        Application.get_env(:cleat_deploy, :drop_max_bytes, @default_max_bytes)

      value ->
        case Integer.parse(value) do
          {bytes, _} when bytes > 0 -> bytes
          _ -> @default_max_bytes
        end
    end
  end

  defp resolve_app(scope, id) do
    case Integer.parse(id) do
      {int, ""} -> fetch(fn -> Apps.get_app!(scope, int) end)
      _ -> fetch(fn -> Apps.get_app_by_slug!(scope, id) end)
    end
  end

  defp fetch(fun) do
    {:ok, fun.()}
  rescue
    Ecto.NoResultsError -> :error
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end
end
