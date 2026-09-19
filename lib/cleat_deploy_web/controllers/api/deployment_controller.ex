defmodule CleatDeployWeb.Api.DeploymentController do
  @moduledoc false

  use CleatDeployWeb, :controller

  alias CleatDeploy.{Apps, Deployments}
  alias CleatDeployWeb.Api.Serializer

  def index(conn, %{"app_id" => app_id}) do
    scope = conn.assigns.current_scope

    case resolve_app(scope, app_id) do
      {:ok, app} ->
        deployments = Deployments.for_app(scope, app)
        json(conn, %{data: Enum.map(deployments, &Serializer.deployment/1)})

      :error ->
        not_found(conn)
    end
  end

  def create(conn, %{"app_id" => app_id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- resolve_app(scope, app_id) do
      attrs = %{
        git_sha: "manual",
        triggered_by: "api",
        git_ref: params["git_ref"]
      }

      case Deployments.enqueue_deployment(scope, app, attrs) do
        {:ok, deployment, _job} ->
          conn
          |> put_status(:created)
          |> json(%{data: Serializer.deployment(deployment)})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "invalid_request", details: errors(changeset)})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: to_string(reason)})
      end
    else
      :error -> not_found(conn)
    end
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case fetch_deployment(scope, id) do
      {:ok, deployment} -> json(conn, %{data: Serializer.deployment(deployment, log: true)})
      :error -> not_found(conn)
    end
  end

  defp fetch_deployment(scope, id) do
    with {int, ""} <- Integer.parse(id) do
      deployment = Deployments.get_deployment!(int)

      if deployment.app.tenant_id == scope.tenant.id do
        {:ok, deployment}
      else
        :error
      end
    else
      _ -> :error
    end
  rescue
    Ecto.NoResultsError -> :error
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

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end
end
