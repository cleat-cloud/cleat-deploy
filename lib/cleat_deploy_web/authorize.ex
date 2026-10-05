defmodule CleatDeployWeb.Authorize do
  @moduledoc """
  LiveView-side companion to `CleatDeploy.Accounts.Scope.can_write?/1`.

  Contexts already refuse writes for members; this gates the events that reach
  functions taking no scope (hibernate/wake, addon rotation, tenant settings)
  so the whole panel follows the same policy as the API.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias CleatDeploy.Accounts.Scope

  @read_only_message "Sua conta tem acesso somente de leitura"

  def read_only_message, do: @read_only_message

  @doc "Runs `fun` when the scope can write; puts a read-only flash otherwise."
  def write(socket, fun) do
    if Scope.can_write?(socket.assigns.current_scope) do
      fun.(socket)
    else
      {:noreply, put_flash(socket, :error, @read_only_message)}
    end
  end
end
