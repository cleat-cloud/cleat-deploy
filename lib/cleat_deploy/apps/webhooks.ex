defmodule CleatDeploy.Apps.Webhooks do
  @moduledoc """
  GitHub push webhooks for registered apps.
  """

  require Logger

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Github
  alias CleatDeploy.Repo

  @doc """
  Provisions (or updates) the GitHub push webhook for an app.

  Returns `{status, app}` where status is `:synced`, `:skipped`, `:no_token`,
  or `{:error, message}`.
  """
  def sync_github_webhook(%App{github_repo: repo} = app) when repo in [nil, ""] do
    {:skipped, app}
  end

  def sync_github_webhook(%App{} = app) do
    if webhook_sync?() do
      do_sync_github_webhook(app)
    else
      {:skipped, app}
    end
  end

  @doc """
  Provisions GitHub push webhooks for every registered app.

  Returns a list of `{slug, status}` tuples where status is `:synced`, `:no_token`,
  `{:renamed, canonical_repo}` when GitHub redirects the stored repo name, or
  `{:error, message}`.
  """
  def sync_all_github_webhooks do
    Repo.all(App)
    |> Enum.map(fn app ->
      {status, _app} = sync_github_webhook(app)
      {app.slug, status}
    end)
  end

  @doc """
  Refreshes the push webhook after an app is repointed at another repo.
  """
  def refresh_after_repo_change(%App{} = app, previous_repo) do
    if is_binary(app.github_repo) and app.github_repo != "" and app.github_repo != previous_repo do
      _ = sync_github_webhook(Repo.preload(app, :server))
    end

    :ok
  end

  @doc "Best-effort removal of the app's GitHub webhook."
  def delete_webhook(%App{} = app) do
    if webhook_sync?() do
      github_client().delete_webhook(app)
    else
      :ok
    end
  end

  defp do_sync_github_webhook(%App{} = app) do
    case github_client().ensure_webhook(app) do
      :ok ->
        {:synced, app}

      {:error, :missing_token} ->
        Logger.warning("GitHub webhook not synced for #{app.slug}: GITHUB_TOKEN is not set")
        {:no_token, app}

      {:error, {:repo_moved, canonical}} ->
        Logger.warning(
          "GitHub repo moved for #{app.slug}: #{app.github_repo} is now #{canonical || "unknown"} " <>
            "(update the app's repo, pushes to the stale name are rejected)"
        )

        {{:renamed, canonical}, app}

      {:error, reason} ->
        message = if is_binary(reason), do: reason, else: inspect(reason)
        Logger.warning("GitHub webhook not synced for #{app.slug}: #{message}")
        {{:error, message}, app}
    end
  end

  defp webhook_sync? do
    Application.get_env(:cleat_deploy, :github_webhook_sync, true)
  end

  defp github_client do
    Application.get_env(:cleat_deploy, :github, Github)
  end
end
