defmodule CleatDeploy.Oban.SafePrunerTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Oban.SafePruner

  test "is ignored during Oban testing modes" do
    assert :ignore = SafePruner.start_link(conf: %{testing: :manual}, name: :safe_pruner_manual)
    assert :ignore = SafePruner.start_link(conf: %{testing: :inline}, name: :safe_pruner_inline)
  end
end
