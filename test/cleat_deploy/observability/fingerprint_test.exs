defmodule CleatDeploy.Observability.FingerprintTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Observability.Fingerprint

  test "groups lines that differ only by pids, ids and numbers" do
    a = Fingerprint.of("GenServer #PID<0.123.0> crashed on request 9981")
    b = Fingerprint.of("GenServer #PID<0.999.0> crashed on request 12")

    assert a == b
    assert is_binary(a)
    assert String.length(a) == 16
  end

  test "keeps distinct messages in distinct groups" do
    refute Fingerprint.of("database timeout") == Fingerprint.of("request completed")
  end
end
