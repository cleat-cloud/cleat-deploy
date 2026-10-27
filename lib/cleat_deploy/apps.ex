defmodule CleatDeploy.Apps do
  @moduledoc """
  Manages Phoenix apps registered for deployment.

  The context is split into `Catalog` (queries), `Lifecycle` (writes), `Ports`
  (allocation), `Env` (variables) and `Webhooks` (GitHub hooks); this module
  keeps the public API stable.
  """

  alias CleatDeploy.Apps.{Catalog, Env, Lifecycle, Ports, Provisioning, Webhooks}

  defdelegate list_apps(scope), to: Catalog
  defdelegate page_size(), to: Catalog
  defdelegate page_apps(scope, opts \\ []), to: Catalog
  defdelegate filtered_apps(scope, opts \\ []), to: Catalog
  defdelegate list_app_choices(scope), to: Catalog
  defdelegate count_apps(scope), to: Catalog
  defdelegate count_by_runtime(scope), to: Catalog
  defdelegate count_by_runtime(scope, server), to: Catalog
  defdelegate get_app!(id), to: Catalog
  defdelegate get_app!(scope, id), to: Catalog
  defdelegate get_app_by_repo(github_repo), to: Catalog
  defdelegate get_app_by_slug!(scope, slug), to: Catalog
  defdelegate list_apps_by_repo(github_repo), to: Catalog
  defdelegate host_registered?(domain), to: Catalog
  defdelegate list_app_instances(scope, app), to: Catalog
  defdelegate list_all_with_servers(), to: Catalog
  defdelegate list_idle_candidates(tenant_id), to: Catalog
  defdelegate count_apps_by_server_id(scope), to: Catalog

  defdelegate allocate_port(server_id, preferred \\ nil), to: Ports

  defdelegate change_app(app, attrs \\ %{}), to: Lifecycle
  defdelegate change_branch(app, attrs \\ %{}), to: Lifecycle
  defdelegate create_app(scope, attrs), to: Lifecycle
  defdelegate update_app(scope, app, attrs), to: Lifecycle
  defdelegate update_app_settings(scope, app, attrs), to: Lifecycle
  defdelegate set_analytics_inject(scope, app, enabled), to: Lifecycle
  defdelegate record_deploy_manifest(app, summary), to: Lifecycle
  defdelegate delete_app(scope, app), to: Lifecycle

  defdelegate sync_github_webhook(app), to: Webhooks
  defdelegate sync_all_github_webhooks(), to: Webhooks

  defdelegate change_env_var(app, attrs \\ %{}), to: Env
  defdelegate put_env_var(app, key, value), to: Env
  defdelegate put_env_var(a, b, c, d), to: Env
  defdelegate put_env_var(scope, app, key, value, branch), to: Env
  defdelegate delete_env_var(app, key), to: Env
  defdelegate delete_env_var(a, b, c), to: Env
  defdelegate delete_env_var(a, b, c, d), to: Env
  defdelegate env_map(app), to: Env
  defdelegate env_map(app, branch), to: Env
  defdelegate sensitive_env_key?(key), to: Env
  defdelegate display_env_value(key, value, reveal?), to: Env
  defdelegate list_env_vars_for_display(app), to: Env

  def provision_from_repo(github_repo, servers \\ []) do
    Provisioning.preset_from_repo(github_repo, servers)
  end
end
