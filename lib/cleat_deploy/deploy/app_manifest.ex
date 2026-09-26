defmodule CleatDeploy.Deploy.AppManifest do
  @moduledoc false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.Addons

  @manifest_path ".cleat_deploy/deploy.json"
  @process_name ~r/^[a-z][a-z0-9_-]*$/
  # Declaring an addon without a profile picks its default one.
  @addon_aliases %{"postgres" => "postgres:pgvector"}

  defstruct solo_server: false,
            caddyfile: nil,
            caddy_mode: "append",
            caddy_listen_port: nil,
            memory_max_mb: 400,
            systemd_unit: nil,
            release_path: nil,
            release_name: nil,
            build_dir: nil,
            runtime: "phoenix",
            binaries: ["server"],
            build_command: nil,
            start_command: nil,
            node_version: nil,
            ruby_version: nil,
            gleam_version: nil,
            release_command: [],
            release_timeout_s: 300,
            processes: %{},
            addons: [],
            domain_checklist?: false

  @type t :: %__MODULE__{
          solo_server: boolean(),
          caddyfile: String.t() | nil,
          caddy_mode: String.t(),
          caddy_listen_port: integer() | nil,
          memory_max_mb: integer(),
          systemd_unit: String.t() | nil,
          release_path: String.t() | nil,
          release_name: String.t() | nil,
          build_dir: String.t() | nil,
          runtime: String.t(),
          binaries: [String.t()],
          build_command: String.t() | nil,
          start_command: String.t() | nil,
          node_version: String.t() | nil,
          ruby_version: String.t() | nil,
          gleam_version: String.t() | nil,
          release_command: [String.t()],
          release_timeout_s: integer(),
          processes: %{String.t() => String.t()},
          addons: [String.t()],
          domain_checklist?: boolean()
        }

  @doc false
  def resolve(repo_path, %App{} = app) when is_binary(repo_path) do
    defaults()
    |> Map.merge(app_overrides(app))
    |> Map.merge(from_mix_exs(repo_path))
    |> Map.merge(from_go_mod(repo_path))
    |> Map.merge(detected_runtime(repo_path, app))
    |> Map.merge(from_repo(repo_path))
    |> then(&struct(__MODULE__, &1))
  end

  @doc false
  def resolve(nil, %App{} = app), do: struct(__MODULE__, app_overrides(app))

  # Infers the runtime from the checked-out repo so a TanStack Start / Next repo
  # deploys as `node` without a committed deploy.json. Only runs while the app is
  # on the default runtime; an explicit deploy.json runtime (merged after) or a
  # non-phoenix app.runtime always wins.
  defp detected_runtime(repo_path, %App{runtime: "phoenix"}) do
    case detect_runtime(repo_path) do
      nil -> %{}
      runtime -> %{runtime: runtime}
    end
  end

  defp detected_runtime(_repo_path, %App{}), do: %{}

  defp detect_runtime(repo_path) do
    cond do
      file?(repo_path, "mix.exs") -> "phoenix"
      file?(repo_path, "go.mod") -> "golang"
      file?(repo_path, "Cargo.toml") -> "rust"
      file?(repo_path, "gleam.toml") -> "gleam"
      rails?(repo_path) -> "rails"
      node_project?(repo_path) -> "node"
      file?(repo_path, "index.html") or file?(repo_path, "package.json") -> "static"
      true -> nil
    end
  end

  defp rails?(repo_path) do
    file?(repo_path, "Gemfile") and
      (file?(repo_path, "config/application.rb") or gemfile_has_rails?(repo_path))
  end

  defp gemfile_has_rails?(repo_path) do
    case File.read(Path.join(repo_path, "Gemfile")) do
      {:ok, contents} -> String.contains?(contents, "rails")
      _ -> false
    end
  end

  defp node_project?(repo_path) do
    with {:ok, contents} <- File.read(Path.join(repo_path, "package.json")),
         {:ok, pkg} <- Jason.decode(contents) do
      deps = Map.merge(pkg["dependencies"] || %{}, pkg["devDependencies"] || %{})
      Enum.any?(Map.keys(deps), &node_framework?/1)
    else
      _ -> false
    end
  end

  defp node_framework?("next"), do: true

  defp node_framework?("@" <> rest),
    do: String.ends_with?(rest, "-start") or String.ends_with?(rest, "/start")

  defp node_framework?(_dep), do: false

  defp file?(repo_path, relative), do: File.exists?(Path.join(repo_path, relative))

  @doc false
  def solo_server?(%__MODULE__{solo_server: true}), do: true
  def solo_server?(_), do: false

  @doc false
  def custom_caddy?(%__MODULE__{caddy_mode: "replace"}), do: true
  def custom_caddy?(_), do: false

  @doc "Commands to run after publishing the release and before the restart."
  def release_commands(%__MODULE__{release_command: commands}) when is_list(commands),
    do: commands

  def release_commands(_manifest), do: []

  @doc "Timeout for each release command, in seconds."
  def release_timeout_s(%__MODULE__{release_timeout_s: seconds})
      when is_integer(seconds) and seconds >= 30,
      do: seconds

  def release_timeout_s(_manifest), do: 300

  @doc """
  Extra systemd units of this app, as suffixes of the base unit.

  Go apps derive them from `binaries` (the `server` binary owns the base unit);
  node/rails with `processes` from the process names (`web` owns the base unit).
  """
  def extra_units(%__MODULE__{runtime: "golang", binaries: binaries}) when is_list(binaries),
    do: Enum.reject(binaries, &(&1 == "server"))

  def extra_units(%__MODULE__{processes: processes})
      when is_map(processes) and map_size(processes) > 0 do
    processes
    |> Map.keys()
    |> Enum.reject(&(&1 == "web"))
    |> Enum.sort()
  end

  def extra_units(_manifest), do: []

  @doc "Long-lived processes declared in deploy.json (empty for single-process apps)."
  def processes(%__MODULE__{processes: processes}) when is_map(processes), do: processes
  def processes(_manifest), do: %{}

  @doc "Declared addons, canonical names, deduplicated."
  def addons(%__MODULE__{addons: addons}) when is_list(addons) do
    addons
    |> Enum.map(&normalize_addon/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def addons(_manifest), do: []

  @doc "Canonical addon name (`postgres` → `postgres:pgvector`), nil when unknown."
  def normalize_addon(name) when is_binary(name) do
    candidate = name |> String.trim() |> String.downcase()
    candidate = Map.get(@addon_aliases, candidate, candidate)

    if candidate in Addons.known(), do: candidate
  end

  def normalize_addon(_name), do: nil

  @doc false
  def validate_for_server(%__MODULE__{} = manifest, server, apps_on_server, %App{} = app) do
    with :ok <- validate_solo_server(manifest, server, apps_on_server, app),
         :ok <- validate_processes(manifest),
         :ok <- validate_addons(manifest) do
      validate_release_timeout(manifest)
    end
  end

  # `processes` must name the HTTP one: it is the process that binds the app port
  # and the one Caddy, the wake agent and the idle sweeper talk to.
  defp validate_processes(%__MODULE__{processes: processes}) when map_size(processes) == 0,
    do: :ok

  defp validate_processes(%__MODULE__{processes: processes}) do
    cond do
      not Map.has_key?(processes, "web") ->
        {:error,
         "processes must declare a \"web\" process: it is the one that binds the app port (in .cleat_deploy/deploy.json)"}

      name = Enum.find(Map.keys(processes), &(not Regex.match?(@process_name, &1))) ->
        {:error,
         "invalid process name #{inspect(name)} in .cleat_deploy/deploy.json (use lower-case letters, digits, - and _)"}

      name = Enum.find(Map.keys(processes), &blank_command?(processes[&1])) ->
        {:error, "process #{inspect(name)} has an empty command in .cleat_deploy/deploy.json"}

      true ->
        :ok
    end
  end

  defp validate_addons(%__MODULE__{addons: []}), do: :ok

  defp validate_addons(%__MODULE__{addons: addons}) do
    case Enum.find(addons, &(normalize_addon(&1) == nil)) do
      nil ->
        :ok

      unknown ->
        {:error,
         "unknown addon #{inspect(unknown)} in .cleat_deploy/deploy.json (known: #{Enum.join(Addons.known(), ", ")})"}
    end
  end

  defp validate_release_timeout(%__MODULE__{release_command: []}), do: :ok

  defp validate_release_timeout(%__MODULE__{release_timeout_s: seconds})
       when is_integer(seconds) and seconds >= 30,
       do: :ok

  defp validate_release_timeout(_manifest) do
    {:error, "release_timeout_s must be at least 30 seconds in .cleat_deploy/deploy.json"}
  end

  defp blank_command?(command) when is_binary(command), do: String.trim(command) == ""
  defp blank_command?(_command), do: true

  defp validate_solo_server(%__MODULE__{solo_server: false}, _server, _apps, _app), do: :ok

  defp validate_solo_server(%__MODULE__{solo_server: true}, server, apps_on_server, app) do
    cond do
      server.deploy_mode != "dedicated" ->
        {:error,
         "This app requires a dedicated server (solo_server in .cleat_deploy/deploy.json)"}

      other_apps_on_server?(apps_on_server, app) ->
        {:error, "Dedicated solo server already hosts another app"}

      true ->
        :ok
    end
  end

  defp other_apps_on_server?(apps, %App{id: id}) do
    Enum.any?(apps, fn %App{id: other_id} -> other_id != id end)
  end

  defp defaults do
    %{
      solo_server: false,
      caddyfile: nil,
      caddy_mode: "append",
      caddy_listen_port: nil,
      memory_max_mb: 400,
      systemd_unit: nil,
      release_path: nil,
      release_name: nil,
      build_dir: nil,
      runtime: "phoenix",
      binaries: ["server"],
      build_command: nil,
      start_command: nil,
      node_version: nil,
      ruby_version: nil,
      gleam_version: nil,
      release_command: [],
      release_timeout_s: 300,
      processes: %{},
      addons: [],
      domain_checklist?: false
    }
  end

  defp app_overrides(%App{} = app) do
    %{
      caddy_listen_port: app.port,
      systemd_unit: app.systemd_unit,
      release_path: app.release_path,
      runtime: app.runtime || "phoenix",
      # Prefer explicit OTP app mapping; may be overridden by mix.exs / deploy.json
      release_name: App.release_name(app)
    }
  end

  defp from_go_mod(repo_path) do
    if File.exists?(Path.join(repo_path, "go.mod")) and
         not File.exists?(Path.join(repo_path, "mix.exs")) do
      binaries =
        ["server", "worker"]
        |> Enum.filter(&File.exists?(Path.join(repo_path, "cmd/#{&1}/main.go")))

      %{runtime: "golang", binaries: binaries_or_default(binaries)}
    else
      %{}
    end
  end

  defp binaries_or_default([]), do: ["server"]
  defp binaries_or_default(binaries), do: binaries

  # When slug != mix app atom (e.g. slug "decor", app :festa_platform), prefer mix.exs.
  defp from_mix_exs(repo_path) do
    mix_path = Path.join(repo_path, "mix.exs")

    with true <- File.exists?(mix_path),
         content <- File.read!(mix_path),
         [_, atom] <- Regex.run(~r/\bapp:\s*:([a-zA-Z0-9_]+)/, content) do
      %{release_name: atom}
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp from_repo(repo_path) do
    path = Path.join(repo_path, @manifest_path)

    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
      |> parse_manifest()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp parse_manifest(map) when is_map(map) do
    %{
      solo_server: truthy?(Map.get(map, "solo_server")),
      caddyfile: blank_to_nil(Map.get(map, "caddyfile")),
      caddy_mode: Map.get(map, "caddy_mode", "append"),
      caddy_listen_port: parse_int(Map.get(map, "caddy_listen_port")),
      memory_max_mb: parse_int(Map.get(map, "memory_max_mb")) || 400,
      systemd_unit: blank_to_nil(Map.get(map, "systemd_unit")),
      release_path: blank_to_nil(Map.get(map, "release_path")),
      release_name: blank_to_nil(Map.get(map, "release_name")),
      build_dir: blank_to_nil(Map.get(map, "build_dir")),
      runtime: parse_runtime(Map.get(map, "runtime")),
      binaries: parse_binaries(Map.get(map, "binaries")),
      build_command: blank_to_nil(Map.get(map, "build_command")),
      start_command: blank_to_nil(Map.get(map, "start_command")),
      node_version: blank_to_nil(Map.get(map, "node_version")),
      ruby_version: blank_to_nil(Map.get(map, "ruby_version")),
      gleam_version: blank_to_nil(Map.get(map, "gleam_version")),
      release_command: parse_release_command(Map.get(map, "release_command")),
      release_timeout_s: parse_int(Map.get(map, "release_timeout_s")),
      processes: parse_processes(Map.get(map, "processes")),
      addons: parse_addons(Map.get(map, "addons")),
      domain_checklist?: Map.get(map, "caddy_mode") == "replace"
    }
    |> Enum.reject(fn {_k, v} -> v in [nil, []] end)
    |> Map.new()
  end

  # deploy.json accepts a single command or a list; both normalize to a list.
  defp parse_release_command(command) when is_binary(command),
    do: parse_release_command([command])

  defp parse_release_command(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_release_command(_command), do: nil

  defp parse_processes(map) when is_map(map) and map_size(map) > 0 do
    map
    |> Enum.filter(fn {name, command} ->
      is_binary(name) and is_binary(command) and String.trim(command) != ""
    end)
    |> Map.new(fn {name, command} -> {String.trim(name), String.trim(command)} end)
  end

  defp parse_processes(_map), do: nil

  defp parse_addons(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_addons(_list), do: nil

  defp parse_runtime("golang"), do: "golang"
  defp parse_runtime("phoenix"), do: "phoenix"
  defp parse_runtime("static"), do: "static"
  defp parse_runtime("node"), do: "node"
  defp parse_runtime("rails"), do: "rails"
  defp parse_runtime("rust"), do: "rust"
  defp parse_runtime("gleam"), do: "gleam"
  defp parse_runtime(_), do: nil

  defp parse_binaries(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_binaries(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
