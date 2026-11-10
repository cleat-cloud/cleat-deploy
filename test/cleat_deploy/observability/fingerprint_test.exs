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

  test "groups Elixir crashes that share frames and differ in pid, line and message" do
    a = elixir_crash("payment declined for alice", 42)
    b = elixir_crash("payment declined for bob", 88)

    assert Fingerprint.of(a) == Fingerprint.of(b)
  end

  test "keeps distinct Elixir exception types in distinct groups" do
    runtime = elixir_crash("boom", 42, "RuntimeError")
    argument = elixir_crash("boom", 42, "ArgumentError")

    refute Fingerprint.of(runtime) == Fingerprint.of(argument)
  end

  test "groups Node stacks by file and function, ignoring line and column" do
    a = node_crash("failed to open /tmp/alice.sock", 12)
    b = node_crash("failed to open /tmp/bob.sock", 88)

    assert Fingerprint.of(a) == Fingerprint.of(b)
  end

  test "groups Python tracebacks by file and function" do
    a = python_crash("ValueError: missing alice", 42)
    b = python_crash("ValueError: missing bob", 10)

    assert Fingerprint.of(a) == Fingerprint.of(b)
  end

  test "groups Go panics by file and function" do
    a = go_panic("missing alice", 12)
    b = go_panic("missing bob", 40)

    assert Fingerprint.of(a) == Fingerprint.of(b)
  end

  test "title/1 returns the exception headline, not the frames" do
    assert Fingerprint.title(elixir_crash("payment failed", 10)) ==
             "** (RuntimeError) payment failed"

    assert Fingerprint.title(node_crash("boom", 12)) == "Error: boom"
    assert Fingerprint.title(python_crash("ValueError: bad item", 10)) == "ValueError: bad item"
    assert Fingerprint.title(go_panic("nil pointer", 12)) == "panic: nil pointer"
    assert Fingerprint.title("segfault at 0 ip 00007fff") == "segfault at 0 ip 00007fff"
  end

  test "exception?/1 detects stacks, panics, logger errors and segfaults" do
    assert Fingerprint.exception?(elixir_crash("boom", 42))
    assert Fingerprint.exception?("[error] payment failed for user 1")
    assert Fingerprint.exception?("console.error Timeout waiting for lock")
    assert Fingerprint.exception?("panic: runtime error")
    assert Fingerprint.exception?("segfault at 0 ip 00007fff")
    refute Fingerprint.exception?("request completed in 12ms")
  end

  defp elixir_crash(message, line, type \\ "RuntimeError") do
    """
    GenServer MyApp.Worker terminating
    ** (#{type}) #{message}
        (my_app 1.0.0) lib/my_app/worker.ex:#{line}: MyApp.Worker.handle_info/2
        (stdlib 6.2) gen_server.erl:1850: :gen_server.try_dispatch/4
    """
  end

  defp node_crash(message, line) do
    """
    Error: #{message}
        at TCPConnectWrap.afterConnect (node:net:1495:16)
        at Object.open (/app/src/db.js:#{line}:3)
    """
  end

  defp python_crash(exception, line) do
    """
    Traceback (most recent call last):
      File "/app/worker.py", line #{line}, in handle
        run(item)
      File "/app/worker.py", line 10, in run
        raise #{exception}
    #{exception}
    """
  end

  defp go_panic(message, line) do
    """
    panic: #{message}

    goroutine 1 [running]:
    main.foo(0x0)
    \t/app/main.go:#{line} +0x20
    main.main()
    \t/app/main.go:6 +0x29
    """
  end
end
