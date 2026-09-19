defmodule CleatDeployWeb.Api.Serializer do
  @moduledoc false

  alias CleatDeploy.Accounts.{ApiToken, Scope, Tenant, User}
  alias CleatDeploy.Apps.App
  alias CleatDeploy.AWS.Lightsail.Bundle
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Servers.Server

  def scope(%Scope{user: user, tenant: tenant, role: role}) do
    %{user: user(user), tenant: tenant(tenant), role: role}
  end

  def user(%User{} = user), do: %{id: user.id, email: user.email}

  def tenant(%Tenant{} = tenant) do
    %{id: tenant.id, name: tenant.name, slug: tenant.slug}
  end

  def api_token(%ApiToken{} = token) do
    %{
      id: token.id,
      name: token.name,
      last_used_at: token.last_used_at,
      inserted_at: token.inserted_at
    }
  end

  def server(%Server{} = server) do
    %{
      id: server.id,
      name: server.name,
      host_ip: server.host_ip,
      ssh_user: server.ssh_user,
      region: server.region,
      provider: server.provider,
      deploy_mode: server.deploy_mode,
      instance_status: server.instance_status,
      bundle_id: server.bundle_id,
      bundle_name: server.bundle_name,
      cpu_count: server.cpu_count,
      ram_mb: server.ram_mb,
      disk_gb: server.disk_gb,
      monthly_price_usd: decimal(server.monthly_price_usd),
      specs_synced_at: server.specs_synced_at,
      inserted_at: server.inserted_at
    }
  end

  def app(%App{} = app) do
    %{
      id: app.id,
      name: app.name,
      slug: app.slug,
      github_repo: blank_to_nil(app.github_repo),
      branch: app.branch,
      host: app.host,
      port: app.port,
      systemd_unit: app.systemd_unit,
      release_path: app.release_path,
      auto_deploy: app.auto_deploy,
      runtime: app.runtime,
      runtime_apt_packages: app.runtime_apt_packages,
      server: server_ref(app),
      inserted_at: app.inserted_at
    }
  end

  def deployment(%Deployment{} = deployment, opts \\ []) do
    base = %{
      id: deployment.id,
      app_id: deployment.app_id,
      git_sha: deployment.git_sha,
      git_ref: deployment.git_ref,
      status: deployment.status,
      triggered_by: deployment.triggered_by,
      started_at: deployment.started_at,
      finished_at: deployment.finished_at,
      inserted_at: deployment.inserted_at,
      updated_at: deployment.updated_at
    }

    if Keyword.get(opts, :log, false) do
      Map.put(base, :log, deployment.log)
    else
      base
    end
  end

  def bundle(%Bundle{} = bundle) do
    %{
      bundle_id: bundle.bundle_id,
      bundle_name: bundle.bundle_name,
      cpu_count: bundle.cpu_count,
      ram_mb: bundle.ram_mb,
      disk_gb: bundle.disk_gb,
      monthly_price_usd: decimal(bundle.monthly_price_usd)
    }
  end

  defp server_ref(%App{server: %Server{} = server}), do: %{id: server.id, name: server.name}
  defp server_ref(%App{server_id: id}) when is_integer(id), do: %{id: id, name: nil}
  defp server_ref(_), do: nil

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: Decimal.to_string(value)

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
