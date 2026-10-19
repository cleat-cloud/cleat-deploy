defmodule CleatDeploy.Apps.AppTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Apps.App

  test "hosts/1 splits comma-separated aliases" do
    app = %App{host: "www.purplestock.com.br, purplestock.com.br, blog.purplestock.com.br"}

    assert App.hosts(app) == [
             "www.purplestock.com.br",
             "purplestock.com.br",
             "blog.purplestock.com.br"
           ]
  end

  test "hosts/1 returns a single host" do
    assert App.hosts(%App{host: "atelie.gestaobem.com"}) == ["atelie.gestaobem.com"]
  end

  test "hosts/1 ignores blank fragments" do
    assert App.hosts(%App{host: " a.com, , b.com "}) == ["a.com", "b.com"]
  end

  test "hosts/1 is empty when host is missing" do
    assert App.hosts(%App{host: nil}) == []
    assert App.hosts(%App{host: ""}) == []
  end
end
