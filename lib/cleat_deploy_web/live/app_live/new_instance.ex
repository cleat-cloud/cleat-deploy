defmodule CleatDeployWeb.AppLive.NewInstance do
  @moduledoc """
  Shared "new instance" behavior of the app pages.

  An instance is another app of the same repository deployed from a different
  branch: its own slug, host, port, systemd unit and environment variables. The
  GitHub push hook is shared, so the webhook secret is inherited from the
  existing instance of that repository.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: CleatDeployWeb.Endpoint,
    router: CleatDeployWeb.Router,
    statics: CleatDeployWeb.static_paths()

  alias CleatDeploy.Apps

  def assigns(socket) do
    app = socket.assigns.app

    socket
    |> assign(:instances, Apps.list_app_instances(socket.assigns.current_scope, app))
    |> assign(:instance_form, to_form(instance_params(%{}), as: :instance))
    |> assign(:instance_defaults, instance_defaults(app, ""))
    |> assign(:instance_errors, [])
    |> assign(:confirming_new_instance?, false)
  end

  def handle_event("open_new_instance", _params, socket) do
    {:noreply,
     socket
     |> assign(:instance_form, to_form(instance_params(%{}), as: :instance))
     |> assign(:instance_defaults, instance_defaults(socket.assigns.app, ""))
     |> assign(:instance_errors, [])
     |> assign(:confirming_new_instance?, true)}
  end

  def handle_event("close_new_instance", _params, socket) do
    {:noreply, assign(socket, :confirming_new_instance?, false)}
  end

  def handle_event("validate_new_instance", %{"instance" => params}, socket) do
    {:noreply,
     socket
     |> assign(:instance_form, to_form(instance_params(params), as: :instance))
     |> assign(:instance_defaults, instance_defaults(socket.assigns.app, params["branch"]))}
  end

  def handle_event("save_new_instance", %{"instance" => params}, socket) do
    app = socket.assigns.app
    defaults = instance_defaults(app, params["branch"])

    attrs = %{
      "branch" => params["branch"],
      "name" => blank_to_default(params["name"], defaults.name),
      "slug" => blank_to_default(params["slug"], defaults.slug),
      "host" => blank_to_default(params["host"], defaults.host),
      "port" => params["port"],
      "github_repo" => app.github_repo,
      "server_id" => app.server_id,
      "runtime" => app.runtime,
      "auto_deploy" => app.auto_deploy
    }

    case Apps.create_app(socket.assigns.current_scope, attrs) do
      {:ok, instance, _status} ->
        {:noreply,
         socket
         |> assign(:confirming_new_instance?, false)
         |> put_flash(:info, "Instance #{instance.slug} created for branch #{instance.branch}")
         |> push_navigate(to: ~p"/apps/#{instance.id}/deployments")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:instance_errors, changeset_errors(changeset))
         |> assign(:instance_defaults, defaults)}
    end
  end

  def handle_event(event, _params, _socket) do
    raise ArgumentError, "unhandled LiveView event #{inspect(event)}"
  end

  defp instance_params(params), do: Map.take(params, ["branch", "name", "slug", "host", "port"])

  # Suggestions for the form: derived from the branch being typed and shown as
  # placeholders, so a blank field keeps them.
  defp instance_defaults(app, branch) do
    case branch_suffix(branch) do
      "" ->
        %{branch: "", name: "", slug: "", host: ""}

      suffix ->
        slug = "#{app.slug}-#{suffix}"

        %{
          branch: branch,
          name: "#{app.name} (#{suffix})",
          slug: slug,
          host: instance_host(app.host, slug)
        }
    end
  end

  defp branch_suffix(branch) do
    branch
    |> to_string()
    |> String.trim()
    |> String.replace_prefix("refs/heads/", "")
    |> String.replace(~r/[^A-Za-z0-9]+/, "-")
    |> String.trim("-")
    |> String.downcase()
  end

  # Instances of the same project are siblings on the same domain, so only the
  # first label of the host changes.
  defp instance_host(host, slug) when is_binary(host) and host != "" do
    case String.split(host, ".", parts: 2) do
      [_label, rest] -> "#{slug}.#{rest}"
      _ -> host
    end
  end

  defp instance_host(_host, _slug), do: ""

  defp blank_to_default(value, default) when value in [nil, ""], do: default
  defp blank_to_default(value, _default) when is_binary(value), do: value
  defp blank_to_default(_value, default), do: default

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, messages} ->
      "#{Phoenix.Naming.humanize(to_string(field))} #{Enum.join(messages, ", ")}"
    end)
  end
end
