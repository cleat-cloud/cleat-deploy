defmodule CleatDeployWeb.FeaturesLive do
  use CleatDeployWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Features")
     |> assign(:active_tab, :landing)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab={@active_tab}
    >
      <div id="features" class="mx-auto max-w-4xl space-y-4">
        <div class="space-y-1">
          <h2 class="font-display text-lg font-semibold tracking-tight text-hd-text">Features</h2>
          <p class="text-xs leading-relaxed text-hd-muted">
            Everything Cleat does today and where to find it. The JSON API under
            <span class="font-mono text-hd-text">/api/v1</span>
            is what the <span class="font-mono text-hd-text">cleat</span>
            CLI talks to, and every key of the deploy manifest is documented in <.link
              id="features-manifest-docs"
              href="https://github.com/cleat-cloud/cleat-deploy/blob/main/docs/deploy-json.md"
              target="_blank"
              rel="noopener noreferrer"
              class="text-hd-blue transition-colors hover:underline"
            >
              docs/deploy-json.md
            </.link>.
          </p>
        </div>

        <div :for={section <- sections()} id={section.id} class="paas-card overflow-hidden">
          <div class="flex items-start gap-3 border-b border-hd-border bg-hd-aside/60 px-4 py-3">
            <div class="flex size-9 shrink-0 items-center justify-center rounded-md border border-hd-border bg-hd-card">
              <.icon name={section.icon} class="size-4 text-hd-orange" />
            </div>
            <div class="min-w-0 space-y-0.5">
              <h3 class="font-display text-sm font-semibold text-hd-text">{section.title}</h3>
              <p class="text-xs leading-relaxed text-hd-muted">{section.hint}</p>
            </div>
          </div>

          <ul>
            <li
              :for={item <- section.items}
              id={item.id}
              class="flex flex-wrap items-center justify-between gap-3 border-b border-hd-border/50 px-4 py-3 last:border-b-0"
            >
              <div class="min-w-0 space-y-0.5">
                <p class="flex flex-wrap items-center gap-2 text-[12px] font-semibold text-hd-text">
                  {item.title}
                  <span
                    :if={item[:code]}
                    class="rounded border border-hd-border bg-hd-aside px-1.5 py-0.5 font-mono text-[10px] font-normal text-hd-orange"
                  >
                    {item.code}
                  </span>
                </p>
                <p class="text-[11px] leading-relaxed text-hd-muted">{item.hint}</p>
              </div>

              <.link
                :if={item[:href]}
                id={"#{item.id}-open"}
                navigate={item.href}
                class="paas-btn-secondary shrink-0 text-[10px] uppercase"
              >
                {item[:link_label] || "Open"}
              </.link>
            </li>
          </ul>
        </div>

        <div
          id="features-cta"
          class="paas-card flex flex-wrap items-center justify-between gap-3 p-4"
        >
          <div class="space-y-0.5">
            <p class="font-display text-sm font-semibold text-hd-text">
              {if @current_scope, do: "Ready to use it", else: "Ready to try it?"}
            </p>
            <p class="text-[11px] text-hd-muted">
              {if @current_scope,
                do: "Everything above is one click away in the panel.",
                else: "Register a server, connect a repository and push to deploy."}
            </p>
          </div>

          <.link :if={@current_scope} navigate={~p"/"} class="paas-btn-primary">
            Open panel
          </.link>

          <div :if={is_nil(@current_scope)} class="flex items-center gap-2">
            <.link
              :if={CleatDeploy.Accounts.registration_allowed?()}
              href={~p"/users/register"}
              class="paas-btn-primary"
            >
              Create account
            </.link>
            <.link href={~p"/users/log-in"} class="paas-btn-secondary">Log in</.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp sections do
    [
      %{
        id: "features-apps",
        title: "Apps",
        icon: "hero-globe-alt",
        hint: "Register a repository, deploy it and configure everything about it.",
        items: [
          %{
            id: "feature-register-app",
            title: "Register App",
            hint:
              "Pick a GitHub repository and the preset fills runtime, host, port, unit and the push webhook.",
            href: ~p"/apps/new"
          },
          %{
            id: "feature-app-list",
            title: "App list with filters",
            hint:
              "Search, filter by runtime, auto sleep opt-in and status, sort any column, paginate.",
            href: ~p"/apps"
          },
          %{
            id: "feature-deploy-now",
            title: "Deploy now",
            hint:
              "Clones the branch, builds on the VM, publishes the release and restarts the unit.",
            href: ~p"/apps"
          },
          %{
            id: "feature-deploy-history",
            title: "Deployments & build log",
            hint: "History per app with status, duration and the full build log of each deploy.",
            href: ~p"/apps"
          },
          %{
            id: "feature-cancel-deploy",
            title: "Cancel deploy",
            hint:
              "Drops the queued job and marks the deployment failed; a build already running is not interrupted.",
            href: ~p"/apps"
          },
          %{
            id: "feature-release-command",
            title: "Release phase",
            hint:
              "release_command runs after the release is published and before the restart, with the app env loaded and a timeout. A failure aborts the deploy and the previous release keeps serving.",
            href: ~p"/apps"
          },
          %{
            id: "feature-processes",
            title: "Multi-process apps",
            hint:
              "processes in deploy.json gives every process its own systemd unit: web keeps the base unit and the port, the others become <unit>-<name> and never bind it.",
            href: ~p"/apps"
          },
          %{
            id: "feature-addons",
            title: "Managed addons",
            hint:
              "addons: [\"postgres:pgvector\", \"redis\"] installs the datastores on the server, creates credentials per app and injects DATABASE_URL / REDIS_URL — rotatable from the app page.",
            href: ~p"/apps"
          },
          %{
            id: "feature-branch-webhook",
            title: "Deploy branch & webhook",
            hint:
              "Auto-deploy only fires for the configured branch; URL and HMAC secret live in the Webhook tab.",
            href: ~p"/apps"
          },
          %{
            id: "feature-env-vars",
            title: "Environment variables",
            hint:
              "Encrypted at rest, synced to /etc/<app>/env on every deploy, secrets masked until revealed.",
            href: ~p"/apps"
          },
          %{
            id: "feature-runtime-packages",
            title: "Runtime packages",
            hint: "Extra apt packages installed on each deploy, per app.",
            href: ~p"/apps"
          },
          %{
            id: "feature-runtime-logs",
            title: "Runtime logs",
            hint: "The last journal lines of the app's systemd unit, refreshed on demand.",
            href: ~p"/apps"
          },
          %{
            id: "feature-domains",
            title: "Tenant domains",
            hint: "Custom domains with on-demand TLS, verified from the panel.",
            href: ~p"/apps"
          },
          %{
            id: "feature-delete-app",
            title: "Delete app",
            hint:
              "Danger zone: stops the unit and removes the release, the Caddy site, env vars and the webhook.",
            href: ~p"/apps"
          }
        ]
      },
      %{
        id: "features-sleep",
        title: "Auto sleep · hibernation",
        icon: "hero-moon",
        hint: "Apps stop using CPU and RAM while idle, and come back on the next request.",
        items: [
          %{
            id: "feature-idle-window",
            title: "Platform switch & idle window",
            hint:
              "Settings → Platform: enable idle shutdown and set the window in minutes (60 by default, minimum 5).",
            href: ~p"/settings?tab=platform",
            link_label: "Settings"
          },
          %{
            id: "feature-idle-optin",
            title: "Per-app opt-in",
            hint:
              "Auto sleep chip in the app hero and the Idle column in the list. The flag only arms on the next deploy of that app.",
            href: ~p"/apps"
          },
          %{
            id: "feature-hibernate",
            title: "Hibernate / Wake up",
            hint:
              "Manual stop and start, with a confirmation dialog. The process dies; release, data dir and Caddy site stay on disk.",
            href: ~p"/apps"
          },
          %{
            id: "feature-wake-on-request",
            title: "Wake on request",
            hint:
              "The deploy installs the cleat-waker agent: Caddy's forward_auth starts the app on the next request and waits until it answers (cold start)."
          },
          %{
            id: "feature-sweeper",
            title: "Idle sweeper",
            hint:
              "An Oban cron runs every 5 minutes and stops the apps that opted in and had no access for the whole window. Only the HTTP process sleeps — workers keep running — and it never stops an app whose wake was not armed."
          },
          %{
            id: "feature-status",
            title: "Status column",
            hint:
              "On / Off per app, read from the systemd state of the unit the panel controls (a Go worker unit does not keep an app looking On).",
            href: ~p"/apps"
          }
        ]
      },
      %{
        id: "features-servers",
        title: "Servers",
        icon: "hero-server-stack",
        hint: "The VMs that run the apps, driven over SSH and through the cloud provider API.",
        items: [
          %{
            id: "feature-provision-server",
            title: "Register / provision a VM",
            hint:
              "Lightsail or Hetzner with cloud-init: Caddy, git, build tools, firewall and the SSH key.",
            href: ~p"/servers/new"
          },
          %{
            id: "feature-inventory",
            title: "Inventory sync",
            hint:
              "Lists instances from the provider, reconciles IPs and marks each one running / missing / private.",
            href: ~p"/servers"
          },
          %{
            id: "feature-power",
            title: "Power on / off",
            hint:
              "Stops or starts the whole VM through the provider API, keeping everything on disk.",
            href: ~p"/servers"
          },
          %{
            id: "feature-resize",
            title: "Resize",
            hint: "Change the instance bundle/plan and sync the specs back into the panel.",
            href: ~p"/servers"
          },
          %{
            id: "feature-insights",
            title: "Insights",
            hint:
              "CPU, network, per-runtime and per-day deploy charts, plus host disk and memory.",
            href: ~p"/"
          }
        ]
      },
      %{
        id: "features-settings",
        title: "Settings",
        icon: "hero-cog-6-tooth",
        hint: "One page, two tabs.",
        items: [
          %{
            id: "feature-settings-platform",
            title: "Platform tab",
            hint: "Idle shutdown switch and the shared idle window for every app of the tenant.",
            href: ~p"/settings?tab=platform"
          },
          %{
            id: "feature-settings-account",
            title: "Account tab",
            hint:
              "Change the email (confirmation link) and the password without losing the session.",
            href: ~p"/settings?tab=account"
          }
        ]
      },
      %{
        id: "features-api",
        title: "JSON API · /api/v1",
        icon: "hero-command-line",
        hint:
          "What the cleat CLI uses. Everything is scoped to the token's tenant; writes need an owner/admin token.",
        items: [
          %{
            id: "feature-api-auth",
            title: "Tokens & identity",
            code: "POST /auth/tokens · DELETE /auth/tokens · GET /me",
            hint:
              "Create and revoke API tokens, and read the user, tenant and role behind the token."
          },
          %{
            id: "feature-api-apps-read",
            title: "Read apps",
            code: "GET /apps · GET /apps/:id · GET /apps/:app_id/env",
            hint:
              "App payload with branch, host, port, unit, runtime, auto_deploy, idle_shutdown_enabled and indexable."
          },
          %{
            id: "feature-api-deploys",
            title: "Deploys",
            code:
              "POST /apps/:app_id/deployments · POST /apps/:app_id/cancel · GET /deployments/:id",
            hint: "Queue a deploy, cancel the queued one and follow status plus the build log."
          },
          %{
            id: "feature-api-apps-write",
            title: "Write apps",
            code: "POST /apps · PATCH /apps/:id · DELETE /apps/:id",
            hint:
              "Create an app, edit branch/host/port/runtime/auto_deploy/idle_shutdown_enabled/indexable, or delete it."
          },
          %{
            id: "feature-api-env",
            title: "Environment",
            code: "PUT /apps/:app_id/env · DELETE /apps/:app_id/env/:key",
            hint:
              "Upsert or delete env vars; sensitive values are masked unless reveal is requested."
          },
          %{
            id: "feature-api-drops",
            title: "Static drops",
            code: "POST /apps/:app_id/drops",
            hint: "Upload a gzipped tarball for a static app and publish it without a git repo."
          },
          %{
            id: "feature-api-servers",
            title: "Servers",
            code:
              "POST /servers · POST /servers/provision · POST /servers/:id/sync | start | stop | resize",
            hint:
              "Create, provision, sync, power and resize the VMs, and read specs plus resize options."
          },
          %{
            id: "feature-webhook",
            title: "GitHub push webhook",
            code: "POST /webhooks/github",
            hint:
              "HMAC-SHA256 verified push that queues a deploy for the app's configured branch."
          }
        ]
      }
    ]
  end
end
