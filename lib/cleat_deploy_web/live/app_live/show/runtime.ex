defmodule CleatDeployWeb.AppLive.Show.Runtime do
  @moduledoc false
  use CleatDeployWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3, connected?: 1, push_navigate: 2]

  alias CleatDeploy.{Apps}
  alias CleatDeploy.Apps.RuntimeControl
  alias CleatDeploy.Deploy.Addons

  def handle_event("select_app", %{"app_id" => app_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/apps/#{app_id}/deployments")}
  end

  def handle_event("refresh_logs", _params, socket) do
    {:noreply, request_logs(socket)}
  end

  def handle_event("validate_branch", %{"app" => params}, socket) do
    form =
      socket.assigns.app
      |> Apps.change_branch(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :app)

    {:noreply, assign(socket, :branch_form, form)}
  end

  def handle_event("save_branch", %{"app" => params}, socket) do
    case Apps.update_app(socket.assigns.current_scope, socket.assigns.app, params) do
      {:ok, app} ->
        app = Apps.get_app!(socket.assigns.current_scope, app.id)

        {:noreply,
         socket
         |> assign(:app, app)
         |> assign(:apps, Apps.list_app_choices(socket.assigns.current_scope))
         |> assign(:branch_form, to_form(Apps.change_branch(app), as: :app))
         |> put_flash(:info, "Auto-deploy now listens to #{app.branch}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :branch_form, to_form(changeset, as: :app))}
    end
  end

  def handle_event("toggle_idle_shutdown", _params, socket) do
    target = not socket.assigns.app.idle_shutdown_enabled

    case Apps.update_app_settings(socket.assigns.current_scope, socket.assigns.app, %{
           "idle_shutdown_enabled" => target
         }) do
      {:ok, app} ->
        app = Apps.get_app!(socket.assigns.current_scope, app.id)

        {:noreply,
         socket
         |> assign(:app, app)
         |> assign(:confirming_idle_sleep?, false)
         |> put_flash(:info, idle_shutdown_flash(app))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:confirming_idle_sleep?, false)
         |> put_flash(:error, "Could not update auto sleep")}
    end
  end

  def handle_event("toggle_indexable", _params, socket) do
    target = not socket.assigns.app.indexable

    case Apps.update_app_settings(socket.assigns.current_scope, socket.assigns.app, %{
           "indexable" => target
         }) do
      {:ok, app} ->
        app = Apps.get_app!(socket.assigns.current_scope, app.id)

        {:noreply,
         socket
         |> assign(:app, app)
         |> put_flash(:info, indexable_flash(app))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update indexing")}
    end
  end

  def handle_event("open_idle_sleep", _params, socket) do
    {:noreply, assign(socket, :confirming_idle_sleep?, true)}
  end

  def handle_event("close_idle_sleep", _params, socket) do
    {:noreply, assign(socket, :confirming_idle_sleep?, false)}
  end

  def handle_event("rotate_addon_prompt", %{"addon" => addon}, socket) do
    {:noreply, assign(socket, :rotating_addon, addon)}
  end

  def handle_event("close_rotate_addon", _params, socket) do
    {:noreply, assign(socket, :rotating_addon, nil)}
  end

  def handle_event("rotate_addon", %{"addon" => addon}, socket) do
    {_addons, _credentials} = Addons.rotate(socket.assigns.app, [addon])

    {:noreply,
     socket
     |> assign(:rotating_addon, nil)
     |> put_flash(:info, "New credentials stored — deploy this app to apply them")
     |> request_addon_status()}
  end

  def handle_event("refresh_addon_status", _params, socket) do
    {:noreply, request_addon_status(socket)}
  end

  def handle_event("open_hibernate", _params, socket) do
    {:noreply, assign(socket, :confirming_hibernate?, true)}
  end

  def handle_event("close_hibernate", _params, socket) do
    {:noreply, assign(socket, :confirming_hibernate?, false)}
  end

  def handle_event("hibernate_app", _params, socket) do
    socket = assign(socket, :confirming_hibernate?, false)

    case RuntimeControl.hibernate(socket.assigns.app) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{socket.assigns.app.name} hibernated — no CPU or RAM until it wakes"
         )
         |> refresh_runtime()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not hibernate: #{reason}")}
    end
  end

  def handle_event("wake_app", _params, socket) do
    case RuntimeControl.wake(socket.assigns.app) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "#{socket.assigns.app.name} is starting")
         |> refresh_runtime()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not wake: #{reason}")}
    end
  end

  def handle_event("validate_delete", %{"delete" => params}, socket) do
    confirm = Map.get(params, "confirm", "")

    {:noreply,
     socket
     |> assign(:delete_confirm, confirm)
     |> assign(:delete_form, to_form(%{"confirm" => confirm}, as: :delete))}
  end

  def handle_event("delete_app", %{"delete" => params}, socket) do
    app = socket.assigns.app
    confirm = params |> Map.get("confirm", "") |> String.trim()

    cond do
      socket.assigns.deploying? ->
        {:noreply, put_flash(socket, :error, "Wait for the running deploy to finish")}

      confirm != app.slug ->
        {:noreply, put_flash(socket, :error, "Type #{app.slug} to confirm deletion")}

      true ->
        case Apps.delete_app(socket.assigns.current_scope, app) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{app.name} was deleted")
             |> push_navigate(to: ~p"/apps")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete #{app.name}")}
        end
    end
  end

  def handle_event(_event, _params, _socket), do: :passthrough

  def idle_shutdown_flash(%{idle_shutdown_enabled: true}),
    do: "Auto sleep on — deploy this app to arm it on the server"

  def idle_shutdown_flash(_app), do: "Auto sleep off"

  def indexable_flash(%{indexable: true}),
    do: "Indexing on — deploy this app to apply it on the server"

  def indexable_flash(_app),
    do: "Indexing off — deploy this app to apply it on the server"

  # Re-reads the systemd state so the status tile and the hibernate button
  # reflect what just happened.
  def refresh_runtime(socket) do
    send(self(), :load_app_memory)
    socket
  end

  def maybe_load_logs(socket, :logs) do
    if connected?(socket), do: request_logs(socket), else: socket
  end

  def maybe_load_logs(socket, _tab), do: socket

  # The addon probe SSHes into the server; only run it when the app declares
  # addons, and let the card show its "checking" state until it answers.
  def request_addon_status(socket) do
    if socket.assigns.addons == [] do
      socket
    else
      send(self(), :load_addon_status)
      assign(socket, :addon_status, nil)
    end
  end

  # The journal read happens in a task; the template shows its "Reading…" state
  # until the result lands.
  def request_logs(socket) do
    send(self(), :load_app_logs)
    assign(socket, :runtime_logs, nil)
  end

  def log_unit(_app, %{unit: unit}), do: unit

  def log_unit(app, _) do
    app.systemd_unit || Apps.App.default_systemd_unit(app.slug, app.runtime || "phoenix")
  end

  def log_lines(%{lines: lines}) when is_list(lines),
    do: Enum.with_index(lines)

  def log_lines(_), do: []

  def log_line_class(line) do
    down = String.downcase(line)

    cond do
      String.contains?(down, "error") or String.contains?(down, "fail") ->
        "text-rose-400"

      String.contains?(down, "warn") ->
        "text-hd-orange"

      true ->
        "text-hd-text"
    end
  end
end
