defmodule CleatDeploy.Deployments do
  @moduledoc """
  Deployment history and status transitions.

  The context is split into `Queue` (enqueue/claim), `Transitions` (terminal
  statuses, cancel and recovery), `History` (listing and counters), `Timing`
  (duration) and `Notifications` (PubSub); this module keeps the public API
  stable.
  """

  alias CleatDeploy.Deployments.{
    History,
    Notifications,
    Queue,
    Timing,
    Transitions
  }

  defdelegate topic(app_id), to: Notifications
  defdelegate subscribe(app), to: Notifications

  defdelegate create_deployment(app, attrs), to: Queue
  defdelegate enqueue(app, attrs), to: Queue
  defdelegate enqueue(scope, app, attrs), to: Queue
  defdelegate enqueue_deployment(app, attrs), to: Queue
  defdelegate enqueue_deployment(scope, app, attrs), to: Queue
  defdelegate enqueue_drop(app, attrs), to: Queue
  defdelegate enqueue_drop(scope, app, attrs), to: Queue

  defdelegate max_running_per_server(), to: Queue
  defdelegate claim_running(deployment), to: Queue
  defdelegate mark_running(deployment), to: Queue
  defdelegate wait_reason(deployment), to: Queue
  defdelegate wait_reason_message(deployment), to: Queue

  defdelegate mark_success(deployment, message), to: Transitions
  defdelegate mark_failed(deployment, message), to: Transitions
  defdelegate cancel(app), to: Transitions
  defdelegate cancel(scope, app), to: Transitions
  defdelegate recover_orphaned_running(booted_at), to: Transitions
  defdelegate recover_orphaned_queued(), to: Transitions

  defdelegate get_deployment!(id), to: History
  defdelegate get_with_log!(id), to: History
  defdelegate get_with_log!(app, id), to: History
  defdelegate history_page_size(), to: History
  defdelegate for_app(app), to: History
  defdelegate for_app(scope, app), to: History
  defdelegate page_for_app(app, page), to: History
  defdelegate page_for_app(scope, app, page), to: History
  defdelegate deploying?(app), to: History
  defdelegate deploying?(scope, app), to: History
  defdelegate daily_status_counts(scope, days), to: History
  defdelegate daily_status_counts(scope, days, server), to: History

  defdelegate duration(deployment, now \\ DateTime.utc_now(:second)), to: Timing
  defdelegate format_duration(seconds), to: Timing
end
