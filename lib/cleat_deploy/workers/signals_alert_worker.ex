defmodule CleatDeploy.Workers.SignalsAlertWorker do
  @moduledoc """
  Evaluates the three default Corte 02 alert rules for every tenant.

  Runs every minute. Health is derived from stored logs and deployments,
  so this worker does not SSH.
  """

  use Oban.Worker, queue: :logs, max_attempts: 1

  alias CleatDeploy.Accounts.{Scope, Tenant}
  alias CleatDeploy.Repo
  alias CleatDeploy.Signals

  @impl Oban.Worker
  def perform(_job) do
    Tenant
    |> Repo.all()
    |> Enum.each(fn tenant ->
      Signals.evaluate_alerts(%Scope{tenant: tenant, role: "owner"})
    end)

    :ok
  end
end
