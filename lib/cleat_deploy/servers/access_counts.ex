defmodule CleatDeploy.Servers.AccessCounts do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Repo
  alias CleatDeploy.Servers.{HostStats, Server}

  @static_ext ~w(.js .css .map .png .jpg .jpeg .gif .svg .ico .woff .woff2 .ttf .eot .webp .avif)

  @default_log "/var/log/caddy/access.log"
  @window_s 86_400
  @limit 8

  # Caddy 2.11 rejects `servers { logs { default_logger_name … } }` in the
  # Caddyfile (`unrecognized servers option 'logs'`). Access events are
  # emitted by a per-site `log` and collected by this named global logger.
  @snippet """
  log access {
  output file /var/log/caddy/access.log {
  roll_size 50MiB
  roll_keep 2
  }
  format json
  include http.log.access
  }
  """

  @bad_servers_logs ~r/servers\s*\{\s*logs\s*\{\s*default_logger_name\s+access\s*\}\s*\}/s

  @ensure_python """
  import re
  import sys

  SNIPPET = \"\"\"log access {
  output file /var/log/caddy/access.log {
  roll_size 50MiB
  roll_keep 2
  }
  format json
  include http.log.access
  }
  \"\"\"

  BAD = re.compile(r"servers\\s*\\{\\s*logs\\s*\\{\\s*default_logger_name\\s+access\\s*\\}\\s*\\}", re.S)

  def ensure(text):
      text = BAD.sub("", text)
      if "include http.log.access" in text and "log access {" in text:
          return text
      start = text.find("{")
      prefix = text[:start] if start >= 0 else ""
      if start >= 0 and prefix.strip() == "":
          depth = 0
          for i, ch in enumerate(text[start:], start):
              if ch == "{":
                  depth += 1
              elif ch == "}":
                  depth -= 1
                  if depth == 0:
                      pad = "" if i > 0 and text[i - 1] == "\\n" else "\\n"
                      return text[:i] + pad + SNIPPET + text[i:]
      return "{\\n" + SNIPPET + "}\\n\\n" + text

  args = [a for a in sys.argv[1:] if a != "-c"]
  if args:
      path = args[0]
      text = open(path).read()
      open(path, "w").write(ensure(text))
  else:
      sys.stdout.write(ensure(sys.stdin.read()))
  """

  def ensure_python, do: String.trim_trailing(@ensure_python)

  def ensure_caddyfile(text) when is_binary(text) do
    text = String.replace(text, @bad_servers_logs, "")

    if String.contains?(text, "include http.log.access") and
         String.contains?(text, "log access {") do
      text
    else
      inject_access_log(text)
    end
  end

  defp inject_access_log(text) do
    case :binary.match(text, "{") do
      {idx, 1} ->
        prefix = binary_part(text, 0, idx)

        if String.trim(prefix) == "" do
          case matching_close(text, idx, 0) do
            nil ->
              wrap_global(text)

            close ->
              pad = if close > 0 and :binary.at(text, close - 1) == ?\n, do: "", else: "\n"

              binary_part(text, 0, close) <>
                pad <> @snippet <> binary_part(text, close, byte_size(text) - close)
          end
        else
          wrap_global(text)
        end

      :nomatch ->
        wrap_global(text)
    end
  end

  defp wrap_global(text), do: "{\n" <> @snippet <> "}\n\n" <> text

  defp matching_close(text, idx, _depth) when idx >= byte_size(text), do: nil

  defp matching_close(text, idx, depth) do
    case :binary.at(text, idx) do
      ?{ -> matching_close(text, idx + 1, depth + 1)
      ?} when depth == 1 -> idx
      ?} -> matching_close(text, idx + 1, depth - 1)
      _ -> matching_close(text, idx + 1, depth)
    end
  end

  def count_hosts(log, opts \\ []) when is_binary(log) do
    now = Keyword.get(opts, :now, System.os_time(:second))
    since = Keyword.get(opts, :since, now - @window_s)

    log
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc -> add_line(acc, line, since) end)
  end

  def count_paths(log, opts \\ []) when is_binary(log) do
    now = Keyword.get(opts, :now, System.os_time(:second))
    since = Keyword.get(opts, :since, now - @window_s)

    log
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc -> add_path_line(acc, line, since) end)
  end

  def rank(apps, counts, opts \\ []) when is_list(apps) and is_map(counts) do
    limit = Keyword.get(opts, :limit, @limit)

    apps
    |> Enum.map(fn app ->
      requests =
        app
        |> app_hosts()
        |> Enum.reduce(0, fn host, acc -> acc + Map.get(counts, host, 0) end)

      %{id: app.id, name: app.name, slug: app.slug, host: app.host, requests: requests}
    end)
    |> Enum.filter(&(&1.requests > 0))
    |> Enum.sort_by(&{&1.requests, &1.slug}, :desc)
    |> Enum.take(limit)
  end

  def for_server(_scope, nil), do: []

  def for_server(%Scope{tenant: tenant}, server) do
    apps =
      Repo.all(
        from a in App,
          where: a.tenant_id == ^tenant.id and a.server_id == ^server.id,
          select: %{id: a.id, name: a.name, slug: a.slug, host: a.host}
      )

    rank(apps, host_counts(server))
  end

  def for_app(scope, app, opts \\ [])

  def for_app(%Scope{tenant: tenant}, %{tenant_id: tenant_id} = app, opts)
      when tenant.id == tenant_id do
    limit = Keyword.get(opts, :limit, @limit)
    now = Keyword.get(opts, :now, System.os_time(:second))
    since = now - range_seconds(Keyword.get(opts, :range, "24h"))
    hosts = MapSet.new(app_hosts(app))

    app
    |> path_counts(since)
    |> Enum.reduce(%{}, fn {{host, path}, n}, acc ->
      if MapSet.member?(hosts, host) do
        Map.update(acc, path, %{path: path, host: host, requests: n}, fn row ->
          %{
            row
            | host: if(n > row.requests, do: host, else: row.host),
              requests: row.requests + n
          }
        end)
      else
        acc
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.requests, &1.path}, :desc)
    |> Enum.take(limit)
  end

  def for_app(%Scope{}, _app, _opts), do: []

  defp host_counts(server) do
    case Application.get_env(:cleat_deploy, :caddy_access_log_path) do
      path when is_binary(path) ->
        read_counts(path)

      _ ->
        if HostStats.local?(server), do: read_counts(@default_log), else: %{}
    end
  end

  defp read_counts(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.reduce(%{}, fn line, acc ->
        add_line(acc, line, System.os_time(:second) - @window_s)
      end)
    else
      %{}
    end
  end

  defp path_counts(app, since) do
    case Application.get_env(:cleat_deploy, :caddy_access_log_path) do
      path when is_binary(path) ->
        read_paths(path, since)

      _ ->
        server = loaded_server(app)
        if server && HostStats.local?(server), do: read_paths(@default_log, since), else: %{}
    end
  end

  defp loaded_server(%{server: %Server{} = server}), do: server
  defp loaded_server(_), do: nil

  defp read_paths(path, since) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.reduce(%{}, fn line, acc -> add_path_line(acc, line, since) end)
    else
      %{}
    end
  end

  defp add_line(acc, line, since) do
    case Jason.decode(line) do
      {:ok, %{"request" => %{"host" => host}} = row} when is_binary(host) and host != "" ->
        if in_window?(row, since) do
          Map.update(acc, normalize_host(host), 1, &(&1 + 1))
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp add_path_line(acc, line, since) do
    case Jason.decode(line) do
      {:ok, %{"request" => request} = row} when is_map(request) ->
        if in_window?(row, since), do: maybe_count_path(acc, request), else: acc

      _ ->
        acc
    end
  end

  defp maybe_count_path(acc, %{"host" => host, "method" => method, "uri" => uri})
       when is_binary(host) and host != "" and is_binary(uri) do
    path = strip_query(uri)

    if get_method?(method) and page_path?(path) do
      Map.update(acc, {normalize_host(host), path}, 1, &(&1 + 1))
    else
      acc
    end
  end

  defp maybe_count_path(acc, _), do: acc

  defp get_method?(method) when is_binary(method), do: String.upcase(method) == "GET"
  defp get_method?(_), do: false

  defp strip_query(uri) do
    uri
    |> String.split("?", parts: 2)
    |> hd()
    |> String.split("#", parts: 2)
    |> hd()
  end

  defp page_path?(path) when is_binary(path) and path != "" do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      String.starts_with?(path, "/_next/static") -> false
      String.starts_with?(path, "/cleat/a") -> false
      ext in @static_ext -> false
      true -> true
    end
  end

  defp page_path?(_), do: false

  defp range_seconds("1h"), do: 3_600
  defp range_seconds("6h"), do: 21_600
  defp range_seconds("24h"), do: 86_400
  defp range_seconds("1d"), do: 86_400
  defp range_seconds("7d"), do: 604_800
  defp range_seconds("90d"), do: 7_776_000
  defp range_seconds(_), do: 86_400

  defp in_window?(%{"ts" => ts}, since) when is_number(ts), do: ts >= since
  defp in_window?(_, _), do: true

  defp app_hosts(%{host: host}) when is_binary(host) do
    host
    |> String.split(",")
    |> Enum.map(&normalize_host/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp app_hosts(_), do: []

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
