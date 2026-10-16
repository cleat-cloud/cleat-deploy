defmodule CleatDeploy.Deploy.Ssh.Session do
  @moduledoc false

  @identity_prefix "cleat_deploy_ssh"

  @exec_from_file """
  #!/bin/sh
  set -eu
  file=$1
  shift
  exec "$@" < "$file"
  """

  def identity_prefix, do: @identity_prefix

  def cleanup_stale_identity_files do
    Path.wildcard(Path.join(System.tmp_dir!(), @identity_prefix <> "*"))
    |> Enum.each(&File.rm/1)
  end

  def ensure_commands(commands) do
    missing =
      Enum.reject(commands, fn cmd ->
        case System.find_executable(cmd) do
          nil -> false
          _ -> true
        end
      end)

    if missing == [] do
      :ok
    else
      {:error, "Missing commands: #{Enum.join(missing, ", ")}"}
    end
  end

  def write_temp_key(%{ssh_private_key_encrypted: key}) when key in [nil, ""],
    do: {:error, "SSH private key not configured on server"}

  def write_temp_key(%{ssh_private_key_encrypted: key}) do
    path = temp_path(@identity_prefix)

    case File.write(path, key) do
      :ok ->
        case File.chmod(path, 0o600) do
          :ok ->
            {:ok, path}

          {:error, reason} ->
            _ = File.rm(path)
            {:error, "Could not write SSH key: #{inspect(reason)}"}
        end

      {:error, reason} ->
        _ = File.rm(path)
        {:error, "Could not write SSH key: #{inspect(reason)}"}
    end
  end

  def temp_path(prefix) when is_binary(prefix) do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}_#{System.system_time(:nanosecond)}_#{:erlang.unique_integer([:positive])}"
    )
  end

  def shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  def log_ssh_base(key_path, target) do
    [
      "-i",
      key_path,
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=8",
      target
    ]
  end

  def ssh_base(key_path, target) do
    [
      "-i",
      key_path,
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "BatchMode=yes",
      "-o",
      "ServerAliveInterval=30",
      "-o",
      "ServerAliveCountMax=120",
      target
    ]
  end

  def scp_base(key_path) do
    [
      "-i",
      key_path,
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "BatchMode=yes",
      "-o",
      "ServerAliveInterval=30",
      "-o",
      "ServerAliveCountMax=120"
    ]
  end

  def cmd(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, output}
    end
  end

  @doc """
  Runs `command` with an argv list and feeds `stdin` to the process.

  OTP 28 cannot close a Port's stdin (`port_command(eof)` is iodata-only),
  so a tiny static wrapper does `exec "$@" < file`. No shell string is
  built from the arguments. Stdin and the wrapper are created 0600/0700
  inside a 0700 directory so umask 0022 never leaves them world-readable.
  """
  def run_with_stdin(command, args, stdin)
      when is_binary(command) and is_list(args) and is_binary(stdin) do
    exec = System.find_executable(command) || command
    dir = temp_path("cleat_ssh_tmp")

    try do
      :ok = mkdir_private(dir)
      stdin_path = Path.join(dir, "stdin")
      wrapper_path = Path.join(dir, "exec_from_file")
      :ok = write_private(stdin_path, stdin, 0o600)
      :ok = write_private(wrapper_path, @exec_from_file, 0o700)
      cmd(wrapper_path, [stdin_path, exec | args])
    after
      File.rm_rf(dir)
    end
  end

  defp mkdir_private(dir) do
    case System.cmd("mkdir", ["-m", "700", dir], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, output}
    end
  end

  defp write_private(path, content, mode) do
    case :file.open(path, [:write, :exclusive, :raw, {:mode, mode}]) do
      {:ok, io} ->
        try do
          :ok = :file.write(io, content)
        after
          :file.close(io)
        end

        File.chmod(path, mode)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def trim(value) when is_binary(value), do: String.trim(value)
  def trim(_), do: ""
end
