defmodule CleatDeploy.Servers.AccessCounts do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Repo
  alias CleatDeploy.Servers.HostStats

  @default_log "/var/log/caddy/access.log"
  @window_s 86_400
  @limit 8

  @snippet """
  servers {
  logs {
  default_logger_name access
  }
  }
  log access {
  output file /var/log/caddy/access.log {
  roll_size 50MiB
  roll_keep 2
  }
  format json
  include http.log.access
  }
  """

  @ensure_python """
  import sys

  SNIPPET = \"\"\"servers {
  logs {
  default_logger_name access
  }
  }
  log access {
  output file /var/log/caddy/access.log {
  roll_size 50MiB
  roll_keep 2
  }
  format json
  include http.log.access
  }
  \"\"\"

  def ensure(text):
      if "default_logger_name access" in text:
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
    if String.contains?(text, "default_logger_name access") do
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

  def rank(apps, counts, opts \\ []) when is_list(apps) and is_map(counts) do
    limit = Keyword.get(opts, :limit, @limit)

    apps
    |> Enum.map(fn app ->
      requests =
        app
        |> app_hosts()
        |> Enum.reduce(0, fn host, acc -> acc + Map.get(counts, host, 0) end)

      %{id: app.id, name: app.name, slug: app.slug, requests: requests}
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
