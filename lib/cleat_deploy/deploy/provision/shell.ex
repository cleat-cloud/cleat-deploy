defmodule CleatDeploy.Deploy.Provision.Shell do
  @moduledoc false

  alias CleatDeploy.Deploy.AppManifest

  @doc "Single-quotes a path for POSIX sh."
  def shell_escape(path) when is_binary(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end

  @doc "Flattens a name into a single-line systemd Description."
  def escape_unit_description(name) when is_binary(name) do
    name |> String.replace(~r/[\r\n]/, " ") |> String.trim()
  end

  @doc """
  Persistent runtime data, kept outside the release directory so deploys do
  not wipe it. Mirrors `App.data_dir/1` but honours a manifest release_path.
  """
  def data_dir_for(%AppManifest{runtime: "static"}, _config), do: nil

  def data_dir_for(%AppManifest{runtime: "phoenix"}, config),
    do: "/var/lib/#{Path.basename(config.release_path)}"

  def data_dir_for(_manifest, config), do: "#{config.release_path}/data"
end
