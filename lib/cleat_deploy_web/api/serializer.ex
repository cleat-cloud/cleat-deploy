defmodule CleatDeployWeb.Api.Serializer do
  @moduledoc false

  alias CleatDeploy.Accounts.{ApiToken, Scope, Tenant, User}
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.Addons
  alias CleatDeploy.AWS.Lightsail.Bundle
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Servers.Server
  alias CleatDeploy.Signals.Alert

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
      data_dir: App.data_dir(app),
      auto_deploy: app.auto_deploy,
      idle_shutdown_enabled: app.idle_shutdown_enabled,
      indexable: app.indexable,
      units: App.unit_names(app),
      addons: Addons.listed(app),
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
      updated_at: deployment.updated_at,
      wait_reason: wait_reason(deployment)
    }

    if Keyword.get(opts, :log, false) do
      Map.put(base, :log, deployment.log)
    else
      base
    end
  end

  def log_event(%LogEvent{} = event) do
    %{
      id: event.id,
      app_id: event.app_id,
      server_id: event.server_id,
      deployment_id: event.deployment_id,
      unit: blank_to_nil(event.unit),
      source: event.source,
      severity: event.severity,
      message: event.message,
      environment: blank_to_nil(event.environment),
      fingerprint: blank_to_nil(event.fingerprint),
      occurred_at: event.occurred_at
    }
  end

  def signal_health(row) do
    %{
      app_id: row.app_id,
      slug: row.slug,
      name: row.name,
      status: Atom.to_string(row.status),
      reasons: Enum.map(row.reasons, &Atom.to_string/1),
      error_count: row.error_count,
      previous_error_count: row.previous_error_count,
      preceding_release: json_release(row.preceding_release)
    }
  end

  def signal_metrics(metrics) do
    %{
      app_id: metrics.app_id,
      slug: metrics.slug,
      range: metrics.range,
      red: metrics.red,
      host: metrics.host,
      series: metrics.series,
      deploy_markers: Enum.map(metrics.deploy_markers, &json_release/1)
    }
  end

  def signal_alert(%Alert{} = alert) do
    %{
      id: alert.id,
      app_id: alert.app_id,
      slug: alert_slug(alert),
      rule: alert.rule,
      status: alert.status,
      message: alert.message,
      channel: alert.channel,
      fired_at: alert.fired_at,
      acked_at: alert.acked_at,
      delivered_at: alert.delivered_at
    }
  end

  def signal_incident(incident) do
    %{
      app_id: incident.app_id,
      slug: incident.slug,
      events: Enum.map(incident.events, &incident_event/1)
    }
  end

  def signal_trace(trace) do
    %{
      trace_id: trace.trace_id,
      root_name: trace.root_name,
      services: trace.services,
      started_at: started_at(trace.started_at_unix_nano),
      duration_ms: div(trace.duration_ns, 1_000_000),
      span_count: trace.span_count,
      error: trace.error
    }
  end

  def signal_span(span) do
    %{
      trace_id: span.trace_id,
      span_id: span.span_id,
      parent_span_id: blank_to_nil(span.parent_span_id),
      name: span.name,
      kind: span.kind,
      service_name: span.service_name,
      status_code: span.status_code,
      start_time_unix_nano: Integer.to_string(span.start_time_unix_nano),
      duration_ms: div(span.duration_ns, 1_000_000),
      depth: span.depth,
      attributes: span.attributes || %{}
    }
  end

  def signal_service_map(map) do
    %{nodes: map.nodes, edges: map.edges}
  end

  def signal_sampling(sampling) do
    %{
      app_id: sampling.app_id,
      slug: sampling.slug,
      trace_sample_rate: sampling.trace_sample_rate
    }
  end

  def signal_trace_detail(detail) do
    %{
      trace: signal_trace(detail.trace),
      spans: Enum.map(detail.spans, &signal_span/1),
      service_map: signal_service_map(detail.service_map),
      logs: Enum.map(detail.logs, &log_event/1)
    }
  end

  def log_group(group) do
    %{
      fingerprint: group.fingerprint,
      severity: group.severity,
      count: group.count,
      sample: group.sample,
      last_seen_at: group.last_seen_at
    }
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

  defp started_at(ns) when is_integer(ns) and ns > 0 do
    ns
    |> div(1_000_000_000)
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp started_at(_), do: nil

  defp alert_slug(%Alert{app: %App{slug: slug}}), do: slug
  defp alert_slug(_alert), do: nil

  defp json_release(nil), do: nil

  defp json_release(release) do
    %{
      id: release.id,
      git_sha: release.git_sha,
      git_ref: Map.get(release, :git_ref) || Map.get(release, "git_ref"),
      status: release.status |> to_string(),
      finished_at: Map.get(release, :finished_at) || Map.get(release, "finished_at")
    }
  end

  defp incident_event(event) do
    %{
      at: event.at,
      kind: Atom.to_string(event.kind),
      summary: event.summary,
      payload: event.payload
    }
  end

  defp wait_reason(deployment) do
    case CleatDeploy.Deployments.wait_reason(deployment) do
      nil -> nil
      reason -> Atom.to_string(reason)
    end
  end
end
