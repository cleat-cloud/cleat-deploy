defmodule CleatDeploy.Analytics.SidecarScriptTest do
  use ExUnit.Case, async: true

  test "python unittests" do
    dir = Application.app_dir(:cleat_deploy, "priv/analytics")

    {output, status} =
      System.cmd("python3", ["-m", "unittest", "test_cleat_analytics.py", "-v"],
        cd: dir,
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
