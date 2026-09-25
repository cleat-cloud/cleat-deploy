defmodule CleatDeployWeb.AppLive.Index do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.{Apps, Github, Servers}
  alias CleatDeploy.Apps.{App, Provisioning, RuntimeControl, RuntimeMemory}
  alias CleatDeployWeb.AppLive.Index.{Directory, Form, Listing, Modals}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Apps")
      |> assign(:active_tab, :apps)
      |> assign(:servers, Servers.list_servers(socket.assigns.current_scope))
      |> assign(:apps_list, [])
      |> assign(:apps_filtered?, false)
      |> assign(:apps_page_ids, nil)
      |> assign(:app_memory, %{})
      |> assign(:memory_ref, nil)
      |> assign(:apps_query, "")
      |> assign(:apps_runtime, :all)
      |> assign(:apps_idle, :all)
      |> assign(:apps_state, :all)
      |> assign(:apps_sort, :name)
      |> assign(:apps_sort_dir, :asc)
      |> assign(:apps_page, 1)
      |> assign(:pending_delete, nil)
      |> assign(:pending_hibernate, nil)
      |> assign(:delete_confirm, "")
      |> assign(:delete_form, to_form(%{"confirm" => ""}, as: :delete))
      |> Listing.restream_apps()

    socket =
      if connected?(socket) do
        send(self(), :load_app_memory)
        socket
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    repos = Github.list_repos()

    socket
    |> assign(:page_title, "New app")
    |> assign(:app, %App{})
    |> assign(:github_repos, repos)
    |> assign(:repo_search, "")
    |> assign(:repo_picker_open?, false)
    |> assign(:show_advanced?, false)
    |> assign(:form, to_form(Apps.change_app(%App{})))
  end

  defp apply_action(socket, :index, params) do
    socket
    |> assign(:page_title, "Apps")
    |> assign(:app, nil)
    |> assign(:form, nil)
    |> assign(:github_repos, [])
    |> assign(:repo_search, "")
    |> assign(:repo_picker_open?, false)
    |> assign(:show_advanced?, false)
    |> Listing.apply_filter_params(params)
  end

  @impl true
  def handle_event("validate", %{"app" => app_params}, socket) do
    {:noreply, Form.apply_form_params(socket, app_params)}
  end

  def handle_event("search_repos", %{"repo_search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:repo_search, query)
     |> assign(:repo_picker_open?, true)}
  end

  def handle_event("open_repo_picker", _params, socket) do
    {:noreply, assign(socket, :repo_picker_open?, true)}
  end

  def handle_event("close_repo_picker", _params, socket) do
    {:noreply, assign(socket, :repo_picker_open?, false)}
  end

  def handle_event("pick_repo", %{"repo" => repo}, socket) do
    {:noreply,
     socket
     |> assign(:repo_search, repo)
     |> assign(:repo_picker_open?, false)
     |> Form.apply_form_params(%{"github_repo" => repo})}
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :show_advanced?, not socket.assigns.show_advanced?)}
  end

  def handle_event("filter_apps", params, socket) do
    query = params["query"] || params["apps_query"] || ""

    {:noreply, push_patch(socket, to: Listing.apps_filter_path(socket, %{query: query}))}
  end

  def handle_event("filter_runtime", %{"runtime" => runtime}, socket) do
    {:noreply,
     push_patch(socket,
       to: Listing.apps_filter_path(socket, %{runtime: Listing.parse_runtime(runtime)})
     )}
  end

  def handle_event("filter_idle", %{"value" => value}, socket) do
    {:noreply,
     push_patch(socket,
       to: Listing.apps_filter_path(socket, %{idle: Listing.parse_toggle(value)})
     )}
  end

  def handle_event("filter_state", %{"value" => value}, socket) do
    {:noreply,
     push_patch(socket,
       to: Listing.apps_filter_path(socket, %{state: Listing.parse_toggle(value)})
     )}
  end

  def handle_event("hibernate_prompt", %{"id" => id}, socket) do
    case Listing.find_app(socket.assigns.apps_list, id) do
      nil -> {:noreply, socket}
      app -> {:noreply, assign(socket, :pending_hibernate, app)}
    end
  end

  def handle_event("close_hibernate", _params, socket) do
    {:noreply, assign(socket, :pending_hibernate, nil)}
  end

  def handle_event("hibernate_app", %{"id" => id}, socket) do
    case Listing.find_app(socket.assigns.apps_list, id) do
      nil ->
        {:noreply, assign(socket, :pending_hibernate, nil)}

      app ->
        case RuntimeControl.hibernate(app) do
          :ok ->
            {:noreply,
             socket
             |> assign(:pending_hibernate, nil)
             |> put_flash(:info, "#{app.name} hibernated — no CPU or RAM until it wakes")
             |> Listing.refresh_runtime()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:pending_hibernate, nil)
             |> put_flash(:error, "Could not hibernate: #{reason}")}
        end
    end
  end

  def handle_event("wake_app", %{"id" => id}, socket) do
    case Listing.find_app(socket.assigns.apps_list, id) do
      nil ->
        {:noreply, socket}

      app ->
        case RuntimeControl.wake(app) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "#{app.name} is starting")
             |> Listing.refresh_runtime()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not wake: #{reason}")}
        end
    end
  end

  def handle_event("delete_app_prompt", %{"id" => id}, socket) do
    case Listing.find_app(socket.assigns.apps_list, id) do
      nil ->
        {:noreply, socket}

      app ->
        {:noreply,
         socket
         |> assign(:pending_delete, app)
         |> assign(:delete_confirm, "")
         |> assign(:delete_form, to_form(%{"confirm" => ""}, as: :delete))}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :pending_delete, nil)}
  end

  def handle_event("validate_delete", %{"delete" => params}, socket) do
    confirm = Map.get(params, "confirm", "")

    {:noreply,
     socket
     |> assign(:delete_confirm, confirm)
     |> assign(:delete_form, to_form(%{"confirm" => confirm}, as: :delete))}
  end

  def handle_event("delete_app", %{"delete" => params}, socket) do
    app = socket.assigns.pending_delete
    confirm = params |> Map.get("confirm", "") |> String.trim()

    cond do
      is_nil(app) ->
        {:noreply, assign(socket, :pending_delete, nil)}

      confirm != app.slug ->
        {:noreply, put_flash(socket, :error, "Type #{app.slug} to confirm deletion")}

      true ->
        case Apps.delete_app(socket.assigns.current_scope, app) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:pending_delete, nil)
             |> assign(:app_count, max(socket.assigns.app_count - 1, 0))
             |> Listing.restream_apps()
             |> put_flash(:info, "#{app.name} was deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete #{app.name}")}
        end
    end
  end

  def handle_event("sort_apps", %{"by" => field}, socket) do
    field = Listing.sort_field(field)

    {sort, dir} =
      if socket.assigns.apps_sort == field do
        {field, Listing.toggle_dir(socket.assigns.apps_sort_dir)}
      else
        {field, :asc}
      end

    {:noreply,
     socket
     |> assign(:apps_sort, sort)
     |> assign(:apps_sort_dir, dir)
     |> assign(:apps_page, 1)
     |> Listing.restream_apps()}
  end

  def handle_event("paginate_apps", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(:apps_page, Listing.parse_page(page))
     |> Listing.restream_apps()}
  end

  def handle_event("save", %{"app" => app_params}, socket) do
    app_params =
      app_params
      |> Form.maybe_put_advanced(socket.assigns.show_advanced?)
      |> then(&Provisioning.apply_preset(&1, socket.assigns.servers))

    case Apps.create_app(socket.assigns.current_scope, app_params) do
      {:ok, app, webhook_status} ->
        {:noreply,
         socket
         |> assign(:apps_page, 1)
         |> Listing.restream_apps()
         |> assign(:app_count, socket.assigns.app_count + 1)
         |> put_flash(:info, Form.app_registered_message(webhook_status))
         |> push_navigate(to: ~p"/apps/#{app.id}/deployments")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def handle_info(:load_app_memory, socket) do
    ref = make_ref()
    {:ok, _pid} = RuntimeMemory.probe_async(self(), ref, socket.assigns.apps_list)

    {:noreply, assign(socket, :memory_ref, ref)}
  end

  def handle_info({:app_memory, ref, memory}, socket) do
    if ref == socket.assigns.memory_ref do
      {:noreply,
       socket
       |> assign(:app_memory, Map.merge(socket.assigns.app_memory, memory))
       |> Listing.restream_apps()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab={@active_tab}
      server_count={@server_count}
      app_count={@app_count}
    >
      <div class="space-y-4">
        <div
          :if={@servers == []}
          class="flex items-center gap-3 rounded-md border border-hd-orange/30 bg-hd-card px-4 py-3 text-sm text-hd-orange"
        >
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>Add a server before registering an app.</span>
        </div>

        <Form.register_form :if={@live_action == :new} {assigns} />
        <Directory.table {assigns} />
        <Modals.dialogs {assigns} />
      </div>
    </Layouts.app>
    """
  end
end
