defmodule CleatDeploy.Deploy.AppManifest do
  @moduledoc false

  alias CleatDeploy.Apps.App

  @manifest_path ".cleat_deploy/deploy.json"

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

  @doc false
  def validate_for_server(%__MODULE__{} = manifest, server, apps_on_server, %App{} = app) do
    validate_solo_server(manifest, server, apps_on_server, app)
  end

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
      build_dir: nil,
      runtime: "phoenix",
      binaries: ["server"],
      build_command: nil,
      start_command: nil,
      node_version: nil,
      ruby_version: nil,
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
      release_name: App.release_name(app.slug)
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
      domain_checklist?: Map.get(map, "caddy_mode") == "replace"
    }
    |> Enum.reject(fn {_k, v} -> v in [nil, []] end)
    |> Map.new()
  end

  defp parse_runtime("golang"), do: "golang"
  defp parse_runtime("phoenix"), do: "phoenix"
  defp parse_runtime("static"), do: "static"
  defp parse_runtime("node"), do: "node"
  defp parse_runtime("rails"), do: "rails"
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
