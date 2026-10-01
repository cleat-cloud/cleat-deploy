defmodule CleatDeployWeb.Internal.DomainAskController do
  @moduledoc """
  Caddy `on_demand_tls` ask endpoint.

  Caddy issues a GET with `?domain=` and treats 2xx as allow. Only loopback
  clients may call this; the panel answers on :4010 so Caddy does not hit a
  tenant app on :4000.
  """

  use CleatDeployWeb, :controller

  alias CleatDeploy.Apps

  def ask(conn, params) do
    cond do
      not loopback?(conn.remote_ip) ->
        send_resp(conn, 403, "")

      not present_domain?(params) ->
        send_resp(conn, 400, "")

      Apps.host_registered?(params["domain"]) ->
        send_resp(conn, 200, "")

      true ->
        send_resp(conn, 404, "")
    end
  end

  defp present_domain?(%{"domain" => domain}) when is_binary(domain) do
    String.trim(domain) != ""
  end

  defp present_domain?(_), do: false

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
