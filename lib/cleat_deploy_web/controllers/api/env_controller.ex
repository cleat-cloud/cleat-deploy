defmodule CleatDeployWeb.Api.EnvController do
  @moduledoc """
  Environment variable endpoints for the `cleat` CLI.

  Variables are scoped to a branch: `"*"` (the default) applies to every deploy
  and any other value restricts the variable to that branch. Sensitive values
  are masked by default; pass `?reveal=true` to return them in the clear.
  Changes take effect on the next deploy.
  """

  use CleatDeployWeb, :controller

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.AppEnvVar

  def index(conn, %{"app_id" => app_id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- resolve_app(scope, app_id) do
      json(conn, %{data: serialize(app, reveal?(params), branch_param(params))})
    else
      :error -> not_found(conn)
    end
  end

  def update(conn, %{"app_id" => app_id} = params) do
    scope = conn.assigns.current_scope
    branch = branch_param(params)

    with {:ok, app} <- resolve_app(scope, app_id),
         {:ok, entries} <- entries(params),
         :ok <- validate_all(app, entries, branch) do
      Enum.each(entries, fn {key, value} -> Apps.put_env_var(app, key, value, branch) end)
      json(conn, %{data: serialize(Apps.get_app!(scope, app.id), false, nil)})
    else
      :error -> not_found(conn)
      {:error, details} -> unprocessable(conn, details)
    end
  end

  def delete(conn, %{"app_id" => app_id, "key" => key} = params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- resolve_app(scope, app_id) do
      case Apps.delete_env_var(app, key, branch_param(params)) do
        :ok -> send_resp(conn, :no_content, "")
        {:error, :not_found} -> not_found(conn)
      end
    else
      :error -> not_found(conn)
    end
  end

  defp entries(%{"vars" => vars}) when is_map(vars) and map_size(vars) > 0 do
    {:ok, Map.to_list(vars)}
  end

  defp entries(%{"key" => key, "value" => value})
       when is_binary(key) and is_binary(value) and key != "" do
    {:ok, [{key, value}]}
  end

  defp entries(_), do: {:error, "provide key/value or a non-empty vars map"}

  defp validate_all(app, entries, branch) do
    invalid =
      entries
      |> Enum.map(fn {key, value} ->
        AppEnvVar.changeset(%AppEnvVar{}, %{
          key: key,
          value: value,
          app_id: app.id,
          branch: branch
        })
      end)
      |> Enum.reject(& &1.valid?)

    case invalid do
      [] -> :ok
      [changeset | _] -> {:error, errors(changeset)}
    end
  end

  # Without a scope every variable is listed; with one, the response holds what
  # a deploy of that branch would receive.
  defp serialize(app, reveal?, branch) do
    app
    |> Apps.list_env_vars_for_display()
    |> Enum.filter(&(is_nil(branch) or AppEnvVar.applies_to?(&1.branch, branch)))
    |> Enum.map(fn %{key: key, value: value, branch: scope, sensitive?: sensitive?} ->
      %{
        key: key,
        value: Apps.display_env_value(key, value, reveal?),
        branch: scope,
        sensitive: sensitive?,
        revealed: reveal? or not sensitive?
      }
    end)
  end

  defp branch_param(params) do
    case params["branch"] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp reveal?(params), do: params["reveal"] in ["true", "1"]

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

  defp unprocessable(conn, details) when is_map(details) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_request", details: details})
  end

  defp unprocessable(conn, message) when is_binary(message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end
end
