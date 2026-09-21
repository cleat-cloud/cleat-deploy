defmodule CleatDeploy.Logs do
  @moduledoc """
  Fetches recent systemd journal lines for an app or a server.

  Options are validated before they are turned into a `journalctl` argument
  list (never a shell string), so untrusted values can never reach a shell.
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Repo
  alias CleatDeploy.Servers.Server

  @unit_pattern ~r/^[A-Za-z0-9:_.@-]+\z/
  @since_iso ~r/^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?\z/
  @since_relative ~r/^\d+(s|m|h|d|w)\z/
  @default_tail 200
  @max_tail 5000
  @max_unit_bytes 128
  @max_since_bytes 32
  @max_grep_bytes 200

  @type normalized :: %{
          unit: String.t() | nil,
          since: String.t() | nil,
          tail: pos_integer(),
          grep: String.t() | nil
        }

  @type error :: {:invalid, String.t()} | {:runtime, String.t()}

  @doc """
  Fetches journal lines for the app's systemd unit.

  The app's systemd unit is always authoritative: any caller-provided `:unit`
  option is ignored so the API contract cannot be overridden.
  """
  @spec fetch_app(App.t(), keyword() | map()) :: {:ok, map()} | {:error, error()}
  def fetch_app(%App{} = app, opts \\ []) do
    app = Repo.preload(app, :server)
    unit = app.systemd_unit || App.default_systemd_unit(app.slug, app.runtime || "phoenix")

    with {:ok, normalized} <- normalize(Keyword.put(to_keyword(opts), :unit, unit)) do
      do_fetch(app, normalized)
    end
  end

  @doc """
  Fetches journal lines for a server.

  `opts[:unit]` is optional; when absent (`nil`) the whole host journal is read.
  """
  @spec fetch_server(Server.t(), keyword() | map()) :: {:ok, map()} | {:error, error()}
  def fetch_server(%Server{} = server, opts \\ []) do
    with {:ok, normalized} <- normalize(opts) do
      do_fetch(server, normalized)
    end
  end

  @doc """
  Validates the journal options.

  Returns `{:ok, %{unit:, since:, tail:, grep:}}` or `{:error, {:invalid, message}}`.
  """
  @spec normalize(keyword() | map()) :: {:ok, normalized()} | {:error, {:invalid, String.t()}}
  def normalize(opts) when is_map(opts), do: normalize(Map.to_list(opts))

  def normalize(opts) when is_list(opts) do
    with {:ok, unit} <- normalize_unit(Keyword.get(opts, :unit)),
         {:ok, since} <- normalize_since(Keyword.get(opts, :since)),
         {:ok, tail} <- normalize_tail(Keyword.get(opts, :tail)),
         {:ok, grep} <- normalize_grep(Keyword.get(opts, :grep)) do
      {:ok, %{unit: unit, since: since, tail: tail, grep: grep}}
    end
  end

  @doc """
  Builds the `journalctl` argv for a normalized option map.
  """
  @spec argv_for(normalized()) :: [String.t()]
  def argv_for(%{unit: unit, since: since, tail: tail}) when is_integer(tail) do
    ["sudo", "journalctl"] ++
      ((unit && ["-u", unit]) || []) ++
      ["-n", Integer.to_string(tail)] ++
      ((since && ["--since", since]) || []) ++
      ["--no-pager", "-o", "short-iso", "--utc"]
  end

  defp do_fetch(subject, normalized) do
    case client().run(subject, argv_for(normalized)) do
      {:ok, output} ->
        lines =
          output
          |> split_lines()
          |> filter_grep(normalized.grep)

        {:ok, %{unit: normalized.unit, lines: lines, fetched_at: DateTime.utc_now(:second)}}

      {:error, reason} ->
        {:error, {:runtime, format_error(reason)}}
    end
  end

  defp client do
    Application.get_env(:cleat_deploy, :runtime_logs, CleatDeploy.Apps.RuntimeLogsSsh)
  end

  defp to_keyword(opts) when is_map(opts), do: Map.to_list(opts)
  defp to_keyword(opts) when is_list(opts), do: opts

  defp normalize_unit(nil), do: {:ok, nil}

  defp normalize_unit(unit) when is_binary(unit) do
    if unit != "" and byte_size(unit) <= @max_unit_bytes and
         Regex.match?(@unit_pattern, unit) do
      {:ok, unit}
    else
      {:error, {:invalid, "invalid unit"}}
    end
  end

  defp normalize_unit(_), do: {:error, {:invalid, "invalid unit"}}

  defp normalize_since(nil), do: {:ok, nil}

  defp normalize_since(since) when is_binary(since) do
    if byte_size(since) <= @max_since_bytes and
         (Regex.match?(@since_iso, since) or Regex.match?(@since_relative, since)) do
      {:ok, since}
    else
      {:error, {:invalid, "invalid since (use 30m, 2h, 1d or 2026-09-21)"}}
    end
  end

  defp normalize_since(_),
    do: {:error, {:invalid, "invalid since (use 30m, 2h, 1d or 2026-09-21)"}}

  defp normalize_tail(nil), do: {:ok, @default_tail}

  defp normalize_tail(tail) when is_binary(tail) do
    case Integer.parse(tail) do
      {value, ""} -> normalize_tail(value)
      _ -> {:error, {:invalid, "tail must be between 1 and #{@max_tail}"}}
    end
  end

  defp normalize_tail(tail) when is_integer(tail) do
    if tail >= 1 and tail <= @max_tail do
      {:ok, tail}
    else
      {:error, {:invalid, "tail must be between 1 and #{@max_tail}"}}
    end
  end

  defp normalize_tail(_), do: {:error, {:invalid, "tail must be between 1 and #{@max_tail}"}}

  defp normalize_grep(nil), do: {:ok, nil}

  defp normalize_grep(grep) when is_binary(grep) do
    if byte_size(grep) <= @max_grep_bytes do
      {:ok, grep}
    else
      {:error, {:invalid, "grep is too long"}}
    end
  end

  defp normalize_grep(_), do: {:error, {:invalid, "grep must be a string"}}

  defp filter_grep(lines, nil), do: lines
  defp filter_grep(lines, grep), do: Enum.filter(lines, &String.contains?(&1, grep))

  defp split_lines(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp format_error(reason) when is_binary(reason) do
    trimmed = String.trim(reason)

    cond do
      trimmed == "" -> "Could not read logs from the VM"
      String.length(trimmed) > 400 -> String.slice(trimmed, 0, 400) <> "…"
      true -> trimmed
    end
  end

  defp format_error(reason), do: "Could not read logs from the VM (#{inspect(reason)})"
end
