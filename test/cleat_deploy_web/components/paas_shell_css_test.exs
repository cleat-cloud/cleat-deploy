defmodule CleatDeployWeb.PaasShellCssTest do
  use ExUnit.Case, async: true

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "centers the desktop sidebar arrow and paints it ember" do
    css = File.read!(@css_path)

    [_, rule] =
      Regex.run(
        ~r/@media \(min-width: 1024px\)[\s\S]*?\.paas-shell-sidebar-toggle \{([^}]+)\}/,
        css
      )

    assert rule =~ "align-self: center;"
    assert rule =~ "color: var(--color-hd-orange);"
    refute rule =~ "align-self: start;"
    refute rule =~ "color: var(--color-hd-muted);"
    refute rule =~ "margin-top:"
  end
end
