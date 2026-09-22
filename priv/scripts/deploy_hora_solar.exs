# Deploy hora-solar to Hetzner cx33:
#   DEPLOY_RUNNER=ssh GITHUB_TOKEN=$(gh auth token) mix run --no-start priv/scripts/deploy_hora_solar.exs

import Ecto.Query

alias CleatDeploy.{Accounts, Apps, Deployments, Repo, Servers}
alias CleatDeploy.Apps.App
alias CleatDeploy.Deploy.SshRunner

for app <- [:crypto, :ecto_sql, :ecto_sqlite3, :cloak, :cloak_ecto] do
  {:ok, _} = Application.ensure_all_started(app)
end

for child <- [CleatDeploy.Repo, CleatDeploy.Vault] do
  {:ok, _} = child.start_link()
end

# create_deployment broadcasta no PubSub — fora do boot completo, subir só ele.
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: CleatDeploy.PubSub}], strategy: :one_for_one)

email = "matheus.puppe@gmail.com"
user = Accounts.get_user_by_email(email) || raise "user not found: #{email}"
scope = Accounts.ensure_scope_for_user(user)
tenant_id = scope.tenant.id

server =
  Repo.one!(
    from s in Servers.Server,
      where: s.tenant_id == ^tenant_id and s.name == "gestaobem-cx33"
  )

IO.puts("==> Server ##{server.id} #{server.name} @ #{server.host_ip}")

app_attrs = %{
  name: "Hora Solar",
  slug: "hora-solar",
  github_repo: "puppe1990/hora-solar",
  branch: "main",
  host: "solar.gestaobem.com",
  port: 4023,
  runtime: "golang",
  systemd_unit: "hora_solar",
  release_path: "/opt/hora_solar",
  server_id: server.id
}

app =
  case Apps.get_app_by_repo("puppe1990/hora-solar") do
    nil ->
      %App{}
      |> App.changeset(Map.put(app_attrs, :tenant_id, tenant_id))
      |> Repo.insert!()

    %{} = existing ->
      existing
      |> Ecto.Changeset.change(Map.put(app_attrs, :tenant_id, tenant_id))
      |> Repo.update!()
  end

app = Apps.get_app!(app.id)

IO.puts("    App ##{app.id} #{app.slug} -> https://#{app.host}")

env = %{
  "PORT" => ":4023",
  "ENV" => "production",
  "DB_PATH" => "/opt/hora_solar/data/app.db",
  "LOCALE" => "pt",
  "APP_URL" => "https://solar.gestaobem.com",
  "BILLING_PLAN" => "starter",
  "CSP_STYLE_SRC" => "https://fonts.googleapis.com",
  "CSP_FONT_SRC" => "https://fonts.gstatic.com",
  "TRUSTED_PROXIES" => "127.0.0.1",
  "WHATSAPP_NUMBER" => "+5511995597242"
}

for {key, value} <- env, is_binary(value) and value != "" do
  {:ok, _} = Apps.put_env_var(app, key, value)
end

# cais.Validate exige em produção; hora-solar não usa para nada além do boot.
app = Apps.get_app!(app.id) |> CleatDeploy.Repo.preload(:env_vars)

unless Enum.any?(app.env_vars, &(&1.key == "ADMIN_TOKEN")) do
  token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  {:ok, _} = Apps.put_env_var(app, "ADMIN_TOKEN", token)
  IO.puts("    ADMIN_TOKEN gerado e salvo no painel (não exibido)")
end

{:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "manual", git_ref: "main"})
IO.puts("==> Deployment ##{deployment.id} — running SshRunner (may take several minutes)...")

started_at = System.monotonic_time(:second)

with {:ok, running} <- Deployments.mark_running(deployment),
     running = Deployments.get_deployment!(running.id),
     {:ok, message} <- SshRunner.deploy(running),
     {:ok, _} <- Deployments.mark_success(running, message) do
  elapsed = System.monotonic_time(:second) - started_at
  IO.puts("\n==> DEPLOY SUCCESS (#{elapsed}s)")
  IO.puts(message)
  System.halt(0)
else
  {:error, reason} ->
    message = if is_binary(reason), do: reason, else: inspect(reason)
    _ = Deployments.mark_failed(Deployments.get_deployment!(deployment.id), message)
    elapsed = System.monotonic_time(:second) - started_at
    IO.puts("\n==> DEPLOY FAILED (#{elapsed}s)")
    IO.puts(message)
    System.halt(1)
end
