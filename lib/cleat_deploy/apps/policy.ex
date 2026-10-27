defmodule CleatDeploy.Apps.Policy do
  @moduledoc false

  alias CleatDeploy.Accounts.Scope

  @doc "Allows writes only for scopes with write access."
  def authorize_write(%Scope{} = scope) do
    if Scope.can_write?(scope), do: :ok, else: {:error, :unauthorized}
  end
end
