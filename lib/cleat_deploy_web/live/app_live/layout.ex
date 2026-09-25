defmodule CleatDeployWeb.AppLive.Layout do
  @moduledoc false

  alias CleatDeployWeb.AppLive.Layout.{Addons, Header, Hero, Tabs, Tiles}

  def shell_header(assigns), do: Header.shell_header(assigns)
  def shell_hero(assigns), do: Hero.shell_hero(assigns)
  def shell_info_tiles(assigns), do: Tiles.shell_info_tiles(assigns)
  def addons_card(assigns), do: Addons.addons_card(assigns)
  def rotate_addon_modal(assigns), do: Addons.rotate_addon_modal(assigns)
  def tab_bar(assigns), do: Tabs.tab_bar(assigns)
  defdelegate detail_tabs(custom_domain_app?, runtime_packages), to: Tabs
  defdelegate parse_detail_tab(tab), to: Tabs
end
