defmodule CleatDeployWeb.AppLive.Show.Env do
  @moduledoc false
  use CleatDeployWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.AppEnvVar

  def handle_event("toggle_secret", _params, socket) do
    {:noreply, assign(socket, :show_secret?, not socket.assigns.show_secret?)}
  end

  def handle_event("toggle_env_values", _params, socket) do
    {:noreply, assign(socket, :show_env_values?, not socket.assigns.show_env_values?)}
  end

  def handle_event("open_env_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:env_form, to_form(Apps.change_env_var(socket.assigns.app), as: :env))
     |> assign(:editing_env_var?, false)
     |> assign(:env_modal_open?, true)}
  end

  def handle_event("edit_env_var", %{"key" => key, "branch" => branch}, socket) do
    case Enum.find(socket.assigns.env_vars, &(&1.key == key and &1.branch == branch)) do
      nil ->
        {:noreply, put_flash(socket, :error, "#{key} is no longer configured")}

      env_var ->
        form =
          socket.assigns.app
          |> Apps.change_env_var(%{
            key: env_var.key,
            value: env_var.value,
            branch: env_var.branch
          })
          |> to_form(as: :env)

        {:noreply,
         socket
         |> assign(:env_form, form)
         |> assign(:editing_env_var?, true)
         |> assign(:env_modal_open?, true)}
    end
  end

  def handle_event("close_env_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:env_form, to_form(Apps.change_env_var(socket.assigns.app), as: :env))
     |> assign(:editing_env_var?, false)
     |> assign(:env_modal_open?, false)}
  end

  def handle_event("validate_env", %{"env" => params}, socket) do
    form =
      socket.assigns.app
      |> Apps.change_env_var(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :env)

    {:noreply, assign(socket, :env_form, form)}
  end

  def handle_event("save_env_var", %{"env" => params}, socket) do
    changeset =
      socket.assigns.app
      |> Apps.change_env_var(params)
      |> Map.put(:action, :validate)

    if changeset.valid? do
      key = Ecto.Changeset.get_field(changeset, :key)
      value = Ecto.Changeset.get_field(changeset, :value)
      branch = Ecto.Changeset.get_field(changeset, :branch)

      case Apps.put_env_var(socket.assigns.app, key, value, branch) do
        {:ok, _env_var} ->
          {:noreply,
           socket
           |> assign(:env_modal_open?, false)
           |> assign(:editing_env_var?, false)
           |> refresh_env_vars()
           |> put_flash(:info, "#{key} saved for #{branch_label(branch)} — deploy to apply")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not save #{key}")}
      end
    else
      {:noreply, assign(socket, :env_form, to_form(changeset, as: :env))}
    end
  end

  def handle_event("delete_env_var", %{"key" => key, "branch" => branch}, socket) do
    case Apps.delete_env_var(socket.assigns.app, key, branch) do
      :ok ->
        {:noreply,
         socket
         |> assign(:env_modal_open?, false)
         |> assign(:editing_env_var?, false)
         |> refresh_env_vars()
         |> put_flash(:info, "#{key} removed for #{branch_label(branch)}")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "#{key} is not configured for that branch")}
    end
  end

  def refresh_env_vars(socket) do
    # Re-read the app: the env_vars preloaded in the socket are stale after a
    # write.
    app = Apps.get_app!(socket.assigns.current_scope, socket.assigns.app.id)

    socket
    |> assign(:app, app)
    |> assign(:env_vars, Apps.list_env_vars_for_display(app))
    |> assign(:env_branches, env_branches(app))
  end

  # Branches offered for scoping a variable: the deploy branch plus whatever is
  # already scoped in this app. "All branches" is the empty/default scope.
  def env_branches(app) do
    app
    |> Apps.list_env_vars_for_display()
    |> Enum.map(& &1.branch)
    |> Kernel.++([app.branch])
    |> Enum.reject(&AppEnvVar.all_branches?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def env_var_row_id(%{key: key, branch: branch}) do
    if AppEnvVar.all_branches?(branch) do
      "env-var-#{key}"
    else
      "env-var-#{key}-#{branch}"
    end
  end

  def branch_label(branch) do
    if AppEnvVar.all_branches?(branch), do: "All branches", else: branch
  end
end
