defmodule CleatDeploy.Analytics do
  @moduledoc """
  Spine analytics defaults. Collection lives on the VPS sidecar, not in cleat.db.
  """

  @runtimes ~w(phoenix golang node rails rust gleam)

  def listen_port do
    Application.get_env(:cleat_deploy, :analytics_listen_port, 8799)
  end

  def product_lp_slugs do
    Application.get_env(:cleat_deploy, :analytics_product_lp_slugs, [])
  end

  def default_inject?(runtime, slug) when is_binary(runtime) and is_binary(slug) do
    runtime in @runtimes or slug in product_lp_slugs()
  end

  def default_inject?(_, _), do: false
end
