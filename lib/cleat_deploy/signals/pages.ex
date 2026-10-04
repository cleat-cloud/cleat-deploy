defmodule CleatDeploy.Signals.Pages do
  @moduledoc """
  Most requested HTTP paths from Caddy access.log, plus sidecar visited pageviews.
  """

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Analytics.Summary
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Servers.AccessCounts

  def for_app(scope, app, opts \\ [])

  def for_app(%Scope{tenant: tenant} = scope, %App{tenant_id: tenant_id} = app, opts)
      when tenant.id == tenant_id do
    range = opts |> Keyword.get(:range, "24h") |> normalize_range()
    limit = Keyword.get(opts, :limit, 8)
    requested = AccessCounts.for_app(scope, app, range: range, limit: limit)
    summary = visited_summary(app, range)

    {:ok,
     %{
       app_id: app.id,
       slug: app.slug,
       range: range,
       requested: Enum.map(requested, &%{path: &1.path, requests: &1.requests}),
       visited: visited_paths(summary),
       pageviews: map_int(summary, :pageviews),
       uniques: map_int(summary, :uniques)
     }}
  end

  def for_app(%Scope{}, %App{}, _opts), do: {:error, :not_found}

  defp visited_summary(app, range) do
    case Summary.app(app.server, summary_host(app), range) do
      {:ok, map} when is_map(map) -> map
      _ -> %{pageviews: 0, uniques: 0, paths: []}
    end
  end

  defp visited_paths(summary) do
    summary
    |> map_get(:paths, [])
    |> List.wrap()
    |> Enum.flat_map(&visited_row/1)
  end

  defp visited_row(%{path: path, pageviews: views}), do: [%{path: path, pageviews: views}]
  defp visited_row(%{"path" => path, "pageviews" => views}), do: [%{path: path, pageviews: views}]
  defp visited_row(_), do: []

  defp summary_host(%{host: host}) when is_binary(host) do
    host
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp summary_host(_), do: ""

  defp map_int(map, key), do: map |> map_get(key, 0) |> to_int()

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(_map, _key, default), do: default

  defp to_int(n) when is_integer(n), do: n
  defp to_int(_), do: 0

  defp normalize_range(range) when range in ["1h", "6h", "24h", "1d", "7d", "90d"], do: range
  defp normalize_range(_), do: "24h"
end
