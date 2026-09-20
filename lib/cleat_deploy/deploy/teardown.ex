defmodule CleatDeploy.Deploy.Teardown do
  @moduledoc """
  Best-effort remote cleanup when an app is deleted from the panel.
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.Ssh
  alias CleatDeploy.Deploy.SshRunner

  def run(%App{} = app) do
    if remote_enabled?() do
      remote(app)
    else
      :ok
    end
  end

  def script(%App{} = app) do
    config = App.deploy_config(app)
    unit = config.systemd_unit
    release_path = config.release_path
    env_file = config.env_file
    host = app.host

    """
    set -u
    UNIT=#{sh_quote(unit)}
    RELEASE=#{sh_quote(release_path)}
    ENVFILE=#{sh_quote(env_file)}
    HOST=#{sh_quote(host)}

    sudo systemctl stop "$UNIT" 2>/dev/null || true
    sudo systemctl disable "$UNIT" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${UNIT}.service"
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo rm -rf "$RELEASE"
    sudo rm -f "$ENVFILE"

    #{remove_host_script(host)}
    """
  end

  @doc """
  Best-effort removal of the Caddy site for `host`, used when an app's host
  changes so the previous vhost does not linger.
  """
  def remove_host(%App{} = app, host) when is_binary(host) do
    if remote_enabled?() do
      case app.server do
        nil -> {:error, :missing_server}
        server -> Ssh.run(server, app, ["bash", "-lc", remove_host_script(host)])
      end
    else
      :ok
    end
  end

  @doc """
  Best-effort removal of a systemd unit, used when an app's runtime changes and
  the unit name is re-derived so the old process does not keep holding the port.
  """
  def remove_unit(%App{} = app, unit) when is_binary(unit) and unit != "" do
    if remote_enabled?() do
      case app.server do
        nil -> {:error, :missing_server}
        server -> Ssh.run(server, app, ["bash", "-lc", remove_unit_script(unit)])
      end
    else
      :ok
    end
  end

  def remove_unit(%App{}, _unit), do: :ok

  @doc "Shell snippet that stops, disables and deletes a systemd unit."
  def remove_unit_script(unit) when is_binary(unit) do
    """
    set -u
    UNIT=#{sh_quote(unit)}
    sudo systemctl stop "$UNIT" 2>/dev/null || true
    sudo systemctl disable "$UNIT" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${UNIT}.service"
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
    """
  end

  @doc "Shell snippet that deletes the Caddy site block for `host` and reloads."
  def remove_host_script(host) when is_binary(host) do
    """
    set -u
    if [[ -f /etc/caddy/Caddyfile ]]; then
      CLEAT_REMOVE_HOST=#{sh_quote(host)} sudo -E python3 - <<'PY'
    import os
    from pathlib import Path

    host = os.environ.get("CLEAT_REMOVE_HOST", "")
    path = Path("/etc/caddy/Caddyfile")
    if not host or not path.exists():
        raise SystemExit(0)

    text = path.read_text()
    needle = host + " {"
    out = []
    i = 0
    changed = False
    while i < len(text):
        idx = text.find(needle, i)
        if idx == -1:
            out.append(text[i:])
            break
        if idx > 0 and text[idx - 1] not in "\\n":
            out.append(text[i:idx + len(needle)])
            i = idx + len(needle)
            continue
        out.append(text[i:idx])
        brace = text.find("{", idx)
        depth = 0
        j = brace
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    j += 1
                    if j < len(text) and text[j] == "\\n":
                        j += 1
                    i = j
                    changed = True
                    break
            j += 1
        else:
            i = len(text)
    new = "".join(out)
    if changed and new != text:
        path.write_text(new)
    PY
      sudo systemctl reload caddy 2>/dev/null || true
    fi
    """
  end

  defp remote(%App{} = app) do
    server = app.server

    if is_nil(server) do
      {:error, :missing_server}
    else
      Ssh.run(server, app, ["bash", "-lc", script(app)])
    end
  end

  defp remote_enabled? do
    Application.get_env(:cleat_deploy, :deploy_runner, CleatDeploy.Deploy.FakeRunner) ==
      SshRunner
  end

  defp sh_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
