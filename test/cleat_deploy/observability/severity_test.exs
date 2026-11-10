defmodule CleatDeploy.Observability.SeverityTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Observability.Severity

  test "promotes journal info/notice exception lines to err" do
    assert Severity.promote("info", "** (RuntimeError) boom") == "err"
    assert Severity.promote("notice", "[error] payment failed") == "err"
    assert Severity.promote("debug", "panic: nil pointer") == "err"
    assert Severity.promote("info", "console.error Timeout") == "err"
    assert Severity.promote("info", "segfault at 0 ip 00007fff") == "err"
  end

  test "keeps severities already at or above err" do
    assert Severity.promote("err", "** (RuntimeError) boom") == "err"
    assert Severity.promote("crit", "panic: boom") == "crit"
    assert Severity.promote("warning", "[error] disk filling") == "warning"
  end

  test "leaves ordinary info lines alone" do
    assert Severity.promote("info", "request completed in 12ms") == "info"
    assert Severity.promote("debug", "GET /health 200") == "debug"
  end
end
