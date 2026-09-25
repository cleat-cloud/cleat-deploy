defmodule CleatDeploy.Deploy.Runner do
  @moduledoc """
  Behaviour for executing app deployments.
  """

  alias CleatDeploy.Deployments.Deployment

  @type deploy_result :: {:ok, String.t()} | {:error, term()}

  @callback deploy(Deployment.t()) :: deploy_result()

  @doc """
  Best-effort stop of a build already running on the app's server.
  """
  @callback interrupt(term(), Deployment.t()) :: :ok | {:error, term()}
end
