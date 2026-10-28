defmodule CleatDeploy.Apps.Env do
  @moduledoc """
  App environment variables: storage, lookup and masking.
  """

  import Ecto.Query, warn: false

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.{App, AppEnvVar, Policy}
  alias CleatDeploy.Repo

  def change_env_var(%App{} = app, attrs \\ %{}) do
    AppEnvVar.changeset(%AppEnvVar{app_id: app.id}, attrs)
  end

  @doc """
  Creates or updates a variable, scoped to a branch (`"*"` by default).
  """
  def put_env_var(app, key, value, branch \\ AppEnvVar.all_branches())

  def put_env_var(%App{} = app, key, value, branch)
      when is_binary(key) and is_binary(value) do
    branch = AppEnvVar.normalize(branch)

    %AppEnvVar{}
    |> AppEnvVar.changeset(%{key: key, value: value, app_id: app.id, branch: branch})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:app_id, :key, :branch]
    )
  end

  def put_env_var(%Scope{} = scope, %App{} = app, key, value) do
    with :ok <- Policy.authorize_write(scope), do: put_env_var(app, key, value)
  end

  def put_env_var(%Scope{} = scope, %App{} = app, key, value, branch) do
    with :ok <- Policy.authorize_write(scope), do: put_env_var(app, key, value, branch)
  end

  @doc """
  Deletes an environment variable from an app.

  Returns `:ok` or `{:error, :not_found}` when the key does not exist for that
  branch scope.
  """
  def delete_env_var(app, key, branch \\ AppEnvVar.all_branches())

  def delete_env_var(%App{} = app, key, branch) when is_binary(key) do
    branch = AppEnvVar.normalize(branch)

    {count, _} =
      Repo.delete_all(
        from v in AppEnvVar,
          where: v.app_id == ^app.id and v.key == ^key and v.branch == ^branch
      )

    if count > 0, do: :ok, else: {:error, :not_found}
  end

  def delete_env_var(%Scope{} = scope, %App{} = app, key) do
    with :ok <- Policy.authorize_write(scope), do: delete_env_var(app, key)
  end

  def delete_env_var(%Scope{} = scope, %App{} = app, key, branch) do
    with :ok <- Policy.authorize_write(scope), do: delete_env_var(app, key, branch)
  end

  @doc """
  Environment of an app as it is written to the server's env file.

  Without a branch every stored variable is returned. With one, the variables
  scoped to all branches are returned and the branch-specific ones override them
  by key.
  """
  def env_map(%App{} = app), do: env_map(app, nil)

  def env_map(%App{} = app, branch) do
    # Force a reload: the deploy path writes env vars (addon credentials) after
    # the struct was loaded and must see them right away.
    vars =
      app
      |> Repo.preload(:env_vars, force: true)
      |> Map.fetch!(:env_vars)
      |> Enum.filter(&(branch == nil or AppEnvVar.applies_to?(&1.branch, branch)))
      |> Enum.sort_by(fn %{branch: scope} ->
        {if(AppEnvVar.all_branches?(scope), do: 0, else: 1), scope}
      end)
      |> Map.new(fn %{key: key, value: value} -> {key, value} end)

    Map.put(vars, "PHX_HOST", app.host)
  end

  @sensitive_markers ~w(SECRET TOKEN PASSWORD _KEY)
  # Connection strings carry the addon password in the userinfo.
  @sensitive_keys ~w(DATABASE_URL REDIS_URL)

  def sensitive_env_key?(key) when is_binary(key) do
    upper = String.upcase(key)

    upper in @sensitive_keys or
      Enum.any?(@sensitive_markers, fn marker ->
        String.contains?(upper, marker)
      end)
  end

  def display_env_value(key, value, reveal?) when is_binary(key) and is_binary(value) do
    if reveal? or not sensitive_env_key?(key) do
      value
    else
      mask_env_value(value)
    end
  end

  def list_env_vars_for_display(%App{} = app) do
    app = Repo.preload(app, :env_vars)

    app.env_vars
    |> Enum.map(fn %{key: key, value: value, branch: branch} ->
      %{key: key, value: value, branch: branch, sensitive?: sensitive_env_key?(key)}
    end)
    |> Enum.sort_by(fn %{key: key, branch: branch} -> {key, branch} end)
  end

  defp mask_env_value(value) do
    len = String.length(value)

    cond do
      len <= 4 ->
        String.duplicate("•", len)

      len <= 8 ->
        String.duplicate("•", 8)

      true ->
        String.slice(value, 0, 2) <>
          String.duplicate("•", min(16, len - 4)) <> String.slice(value, -2, 2)
    end
  end
end
