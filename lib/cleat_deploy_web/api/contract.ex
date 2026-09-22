defmodule CleatDeployWeb.Api.Contract do
  @moduledoc """
  Canonical JSON keys for `/api/v1` responses.

  This is the single source of truth for the API shape consumed by the `cleat`
  CLI. `priv/api_contract.json` must match this module, and the CLI vendors a
  copy of that file in `test/fixtures/api_contract.json`.
  """

  @resources %{
    "app" => ~w(
      id name slug github_repo branch host port systemd_unit release_path data_dir
      auto_deploy idle_shutdown_enabled units addons runtime runtime_apt_packages server inserted_at
    ),
    "server" => ~w(
      id name host_ip ssh_user region provider deploy_mode instance_status
      bundle_id bundle_name cpu_count ram_mb disk_gb monthly_price_usd
      specs_synced_at inserted_at
    ),
    "deployment" => ~w(
      id app_id git_sha git_ref status triggered_by started_at finished_at
      inserted_at updated_at
    ),
    "deployment_log" => ~w(
      id app_id git_sha git_ref status triggered_by started_at finished_at
      inserted_at updated_at log
    ),
    "env_var" => ~w(key value sensitive revealed),
    "user" => ~w(id email),
    "tenant" => ~w(id name slug),
    "me" => ~w(user tenant role),
    "token" => ~w(token token_id user tenant)
  }

  def resources, do: @resources

  def keys(resource) when is_binary(resource), do: Map.fetch!(@resources, resource)
end
