defmodule CleatDeployWeb.AppLive.Show.Deploy do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CleatDeploy.Deployments

  @poll_ms 15_000

  def poll_ms, do: @poll_ms

  def handle_event("deploy", _params, socket) do
    case Deployments.enqueue(socket.assigns.current_scope, socket.assigns.app, %{
           git_sha: "manual",
           triggered_by: "manual"
         }) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:deploying?, true)
         |> schedule_poll(true)
         |> put_flash(:info, "Deploy queued")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue deploy")}
    end
  end

  def handle_event("open_cancel_deploy", _params, socket) do
    {:noreply, assign(socket, :confirming_cancel?, true)}
  end

  def handle_event("close_cancel_deploy", _params, socket) do
    {:noreply, assign(socket, :confirming_cancel?, false)}
  end

  def handle_event("cancel_deploy", _params, socket) do
    socket = assign(socket, :confirming_cancel?, false)

    case Deployments.cancel(socket.assigns.current_scope, socket.assigns.app) do
      {:ok, deployment} ->
        {:noreply,
         socket
         |> refresh_deploying()
         |> put_flash(:info, "Deploy ##{deployment.id} cancelled")}

      {:error, :no_active_deployment} ->
        {:noreply, put_flash(socket, :error, "No deploy queued or running")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not cancel the deploy")}
    end
  end

  def refresh_deploying(socket) do
    deploying? = Deployments.deploying?(socket.assigns.current_scope, socket.assigns.app)

    socket
    |> assign(:deploying?, deploying?)
    |> schedule_poll(deploying?)
  end

  def schedule_poll(socket, true) do
    Process.send_after(self(), :poll_deployments, poll_ms())
    socket
  end

  def schedule_poll(socket, false), do: socket

  def webhook_url do
    CleatDeployWeb.Endpoint.url() <> "/webhooks/github"
  end
end
