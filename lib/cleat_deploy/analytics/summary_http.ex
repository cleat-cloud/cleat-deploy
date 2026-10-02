defmodule CleatDeploy.Analytics.SummaryHttp do
  @moduledoc false

  alias CleatDeploy.Analytics
  alias CleatDeploy.Deploy.Ssh
  alias CleatDeploy.Servers.HostStats

  def visited(server) do
    case get(server, "/v1/visited", range: "24h") do
      {:ok, body} -> decode_visited(body)
      {:error, reason} -> {:error, reason}
    end
  end

  def app(server, host, range) when is_binary(host) and is_binary(range) do
    path = "/v1/apps/" <> URI.encode(host, &URI.char_unreserved?/1)

    case get(server, path, range: range) do
      {:ok, body} -> decode_app(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp get(server, path, params) do
    cond do
      not is_map(server) ->
        {:error, :invalid_server}

      HostStats.local?(server) ->
        local_get(path, params)

      not match?(%{host_ip: host_ip} when is_binary(host_ip), server) ->
        {:error, :invalid_server}

      true ->
        ssh_get(server, path, params)
    end
  end

  defp local_get(path, params) do
    case Req.get(loopback_url(path),
           params: params,
           connect_options: [timeout: 3_000],
           receive_timeout: 3_000,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp ssh_get(server, path, params) do
    if ssh_ready?(server) do
      timed_ssh_get(server, path, params)
    else
      {:error, :invalid_server}
    end
  end

  defp ssh_ready?(server) do
    user = Map.get(server, :ssh_user)
    key = Map.get(server, :ssh_private_key_encrypted)
    is_binary(user) and user != "" and is_binary(key) and key != ""
  end

  defp timed_ssh_get(server, path, params) do
    url = loopback_url(path) <> "?" <> URI.encode_query(params)

    task =
      Task.async(fn ->
        try do
          Ssh.run(server, %{host: Map.fetch!(server, :host_ip)}, [
            "curl",
            "--max-time",
            "3",
            "-sS",
            url
          ])
        rescue
          exception -> {:error, exception}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, output}} -> {:ok, output}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, other}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp loopback_url(path), do: "http://127.0.0.1:#{Analytics.listen_port()}#{path}"

  defp decode_visited(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_visited(decoded)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_visited(list) when is_list(list) do
    {:ok, Enum.map(list, &visited_row/1)}
  end

  defp decode_visited(_body), do: {:error, :invalid_payload}

  defp visited_row(row) when is_map(row) do
    %{
      host: string_field(row, :host),
      slug: string_field(row, :slug),
      pageviews: int_field(row, :pageviews)
    }
  end

  defp visited_row(_row), do: %{host: "", slug: "", pageviews: 0}

  defp decode_app(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_app(decoded)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_app(row) when is_map(row) do
    {:ok,
     %{
       pageviews: int_field(row, :pageviews),
       uniques: int_field(row, :uniques),
       series: Enum.map(list_field(row, :series), &series_row/1),
       paths: Enum.map(list_field(row, :paths), &path_row/1),
       referrers: Enum.map(list_field(row, :referrers), &referrer_row/1),
       utm: Enum.map(list_field(row, :utm), &utm_row/1),
       stale: false
     }}
  end

  defp decode_app(_body), do: {:error, :invalid_payload}

  defp series_row(row) when is_map(row) do
    %{t: string_field(row, :t), pageviews: int_field(row, :pageviews)}
  end

  defp series_row(_row), do: %{t: "", pageviews: 0}

  defp path_row(row) when is_map(row) do
    %{path: string_field(row, :path), pageviews: int_field(row, :pageviews)}
  end

  defp path_row(_row), do: %{path: "", pageviews: 0}

  defp referrer_row(row) when is_map(row) do
    %{referrer: string_field(row, :referrer), pageviews: int_field(row, :pageviews)}
  end

  defp referrer_row(_row), do: %{referrer: "", pageviews: 0}

  defp utm_row(row) when is_map(row) do
    %{
      source: string_field(row, :source),
      medium: string_field(row, :medium),
      campaign: string_field(row, :campaign),
      pageviews: int_field(row, :pageviews)
    }
  end

  defp utm_row(_row), do: %{source: "", medium: "", campaign: "", pageviews: 0}

  defp list_field(map, key) do
    case field(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp string_field(map, key) do
    case field(map, key) do
      value when is_binary(value) -> value
      nil -> ""
      value -> to_string(value)
    end
  end

  defp int_field(map, key) do
    case field(map, key) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        trunc(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp field(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
