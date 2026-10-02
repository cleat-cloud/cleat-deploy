defmodule CleatDeploy.Observability.Redact do
  @moduledoc """
  Masks secrets in collected log lines before they hit the store.
  """

  @placeholder "[redacted]"

  @patterns [
    ~r/(?i)\b(password|passwd|secret|token|api[_-]?key|authorization|bearer)\s*[:=]\s*\S+/,
    ~r/(?i)\b(postgres(?:ql)?|mysql|mongodb|redis|amqp):\/\/\S+/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/,
    ~r/(?i)\b(privKey|pubKey|rootKey|remoteIdentityKey|baseKey)\s*:\s*<Buffer [^>]+>/
  ]

  @spec message(String.t()) :: String.t()
  def message(message) when is_binary(message) do
    Enum.reduce(@patterns, message, &Regex.replace(&1, &2, @placeholder))
  end

  def message(_), do: ""
end
