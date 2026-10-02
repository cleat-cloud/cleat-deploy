defmodule CleatDeploy.Analytics.Hosts do
  @moduledoc false
  import Ecto.Query
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Repo

  def payload(server_id) when is_integer(server_id) do
    from(a in App,
      where: a.server_id == ^server_id and a.analytics_inject == true,
      select: {a.host, a.slug, a.port}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {host, slug, port} ->
      value = %{"slug" => slug, "upstream" => "127.0.0.1:#{port}"}

      host
      |> host_aliases()
      |> Enum.map(&{&1, value})
    end)
    |> Map.new()
  end

  defp host_aliases(host) when is_binary(host) do
    host
    |> String.split(",")
    |> Enum.map(&normalize_host/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("http://", "")
    |> String.replace_prefix("https://", "")
    |> String.split(":")
    |> hd()
  end
end
