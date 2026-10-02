defmodule CleatDeploy.AnalyticsTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Analytics

  test "runtimes default on" do
    for runtime <- ~w(phoenix golang node rails rust gleam) do
      assert Analytics.default_inject?(runtime, "nfe-facil")
    end
  end

  test "generic static defaults off" do
    refute Analytics.default_inject?("static", "memo-drop")
  end

  test "product LP slugs default on even when static" do
    for slug <- ~w(cleat cleat-paas fagulha) do
      assert Analytics.default_inject?("static", slug)
    end
  end

  test "listen port is 8799" do
    assert Analytics.listen_port() == 8799
  end
end
