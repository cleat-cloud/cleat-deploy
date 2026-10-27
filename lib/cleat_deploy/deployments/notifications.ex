defmodule CleatDeploy.Deployments.Notifications do
  @moduledoc """
  PubSub notifications for deployment changes.
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.Deployment

  def topic(app_id) when is_integer(app_id), do: "deployments:#{app_id}"

  def subscribe(%App{id: app_id}), do: subscribe(app_id)

  def subscribe(app_id) when is_integer(app_id) do
    Phoenix.PubSub.subscribe(CleatDeploy.PubSub, topic(app_id))
  end

  @doc "Broadcasts a successful `{:ok, deployment}` and returns it unchanged."
  def broadcast_change({:ok, %Deployment{} = deployment} = result) do
    Phoenix.PubSub.broadcast(
      CleatDeploy.PubSub,
      topic(deployment.app_id),
      {:deployment_changed, deployment.app_id}
    )

    result
  end

  def broadcast_change(other), do: other
end
