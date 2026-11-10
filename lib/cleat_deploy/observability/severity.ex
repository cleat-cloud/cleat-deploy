defmodule CleatDeploy.Observability.Severity do
  @moduledoc """
  Raises journald notice/info/debug lines to `err` when the message is a
  crash or logger error, so they join `group_errors/2`.
  """

  alias CleatDeploy.Observability.Fingerprint

  @promotable ~w(notice info debug)

  @spec promote(String.t(), String.t()) :: String.t()
  def promote(severity, message) when is_binary(severity) and is_binary(message) do
    if severity in @promotable and Fingerprint.exception?(message) do
      "err"
    else
      severity
    end
  end

  def promote(severity, _), do: severity
end
