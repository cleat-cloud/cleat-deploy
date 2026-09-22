defmodule CleatDeploy.Deploy.Wake do
  @moduledoc """
  Wake-on-request agent for apps that opted into idle shutdown.

  Caddy fronts each opted-in site with a `forward_auth` call to a small agent
  (`cleat-waker`) listening on loopback. Every request refreshes the app's
  stamp file — that timestamp is how the panel measures idle time — and a
  request that finds the app stopped starts its systemd unit and waits for the
  app to accept connections before letting the proxy call through.

  The stamp file is the contract between the panel and the server: it exists
  only after the site was written with `forward_auth` and the agent was verified
  reachable, so the sweeper can stop an app knowing the next request wakes it.
  """

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest

  @waker_unit "cleat-waker"
  @waker_path "/usr/local/lib/cleat/waker.py"
  @stamp_dir "/var/lib/cleat/stamps"
  @default_wake_port 3900

  @doc """
  Whether this app's next deploy should be armed for wake-on-request.

  Static sites have no process to start and a custom Caddyfile (`caddy_mode:
  replace`) is not managed by the panel, so neither can be woken.
  """
  def enabled?(%App{} = app, %AppManifest{} = manifest) do
    app.idle_shutdown_enabled == true and manifest.runtime != "static" and
      not custom_caddyfile?(manifest)
  end

  defp custom_caddyfile?(%AppManifest{caddy_mode: "replace", caddyfile: path})
       when is_binary(path) and path != "",
       do: true

  defp custom_caddyfile?(%AppManifest{}), do: false

  # Loopback only. Kept below the `Apps` port pool (4000..32767) so the
  # allocator can never hand this port to an app.
  def wake_port, do: Application.get_env(:cleat_deploy, :wake_port, @default_wake_port)

  def waker_unit, do: @waker_unit

  def stamp_dir, do: @stamp_dir

  def stamp_path(unit) when is_binary(unit), do: "#{@stamp_dir}/#{unit}.stamp"

  @doc """
  Installs (or refreshes) the wake agent on the host and fails the deploy when
  it does not answer.

  Failing loudly is deliberate: an app armed for idle shutdown without a working
  agent would be stopped and never woken again, so the deploy must not write a
  site whose `forward_auth` has nothing to talk to.
  """
  def install_script(unit) when is_binary(unit) do
    """
    log "Installing wake agent (#{@waker_unit})"
    sudo mkdir -p /usr/local/lib/cleat #{@stamp_dir}

    cat > /tmp/cleat_waker.py <<'CLEAT_WAKER_PY'
    #{String.trim_trailing(waker_script())}
    CLEAT_WAKER_PY

    cat > /tmp/cleat_waker.service <<'CLEAT_WAKER_UNIT'
    #{String.trim_trailing(waker_unit_file())}
    CLEAT_WAKER_UNIT

    WAKER_CHANGED=0
    if ! sudo cmp -s /tmp/cleat_waker.py #{@waker_path}; then WAKER_CHANGED=1; fi
    UNIT_CHANGED=0
    if ! sudo cmp -s /tmp/cleat_waker.service /etc/systemd/system/#{@waker_unit}.service; then UNIT_CHANGED=1; fi

    sudo install -m 0755 -o root -g root /tmp/cleat_waker.py #{@waker_path}
    sudo install -m 0644 -o root -g root /tmp/cleat_waker.service /etc/systemd/system/#{@waker_unit}.service
    rm -f /tmp/cleat_waker.py /tmp/cleat_waker.service

    sudo systemctl daemon-reload || true
    sudo systemctl enable #{@waker_unit} > /dev/null 2>&1 || true

    if [ "$WAKER_CHANGED" = "1" ] || [ "$UNIT_CHANGED" = "1" ]; then
      sudo systemctl restart #{@waker_unit} || true
    else
      sudo systemctl start #{@waker_unit} 2>/dev/null || true
    fi

    WAKE_READY=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/#{wake_port()}" 2>/dev/null; then
        WAKE_READY=1
        break
      fi
      sleep 0.5
    done

    if [ "$WAKE_READY" = "1" ]; then
      log "Wake agent listening on 127.0.0.1:#{wake_port()}"
    else
      sudo rm -f #{sh_quote(stamp_path(unit))}
      log "Wake agent did not come up; idle shutdown was NOT armed for #{unit}"
      sudo systemctl status #{@waker_unit} --no-pager 2>/dev/null || true
      sudo journalctl -u #{@waker_unit} -n 20 --no-pager 2>/dev/null || true
      exit 1
    fi
    """
    |> String.trim()
  end

  @doc """
  Marks an app as armed for wake-on-request.

  Runs after the Caddy site was written, so the stamp never exists for a site
  Caddy cannot wake.
  """
  def arm_script(unit) when is_binary(unit) do
    """
    log "Arming idle shutdown for #{unit}"
    sudo mkdir -p #{@stamp_dir}
    sudo chmod 0755 #{@stamp_dir}
    sudo touch #{sh_quote(stamp_path(unit))}
    """
    |> String.trim()
  end

  @doc "Removes the stamp so the sweeper never stops an app that cannot be woken."
  def disarm_script(nil), do: ""

  def disarm_script(unit) when is_binary(unit) and unit != "" do
    "sudo rm -f #{sh_quote(stamp_path(unit))}"
  end

  def disarm_script(_unit), do: ""

  @doc false
  def waker_script do
    """
    # Cleat wake agent.
    #
    # Caddy calls GET /wake?unit=<unit>&port=<port> through forward_auth before
    # proxying a request. 2xx lets the request continue; 503 means the app did
    # not come up. Every call also refreshes the app's stamp file, which is how
    # the panel measures idle time.

    import os
    import re
    import socket
    import subprocess
    import threading
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import parse_qs, urlparse

    LISTEN_ADDRESS = "127.0.0.1"
    LISTEN_PORT = #{wake_port()}
    STAMP_DIR = "#{stamp_dir()}"
    STAMP_INTERVAL_SECONDS = 1.0
    PORT_WAIT_SECONDS = 25.0
    UNIT_PATTERN = re.compile(r"^[A-Za-z0-9:_.@-]+$")

    _locks = {}
    _locks_lock = threading.Lock()
    _stamp_written = {}


    def stamp_path(unit):
        return os.path.join(STAMP_DIR, unit + ".stamp")


    def unit_lock(unit):
        with _locks_lock:
            return _locks.setdefault(unit, threading.Lock())


    def touch_stamp(unit):
        # Throttled: a busy app would otherwise rewrite the file per request.
        now = time.time()
        if _stamp_written.get(unit, 0) + STAMP_INTERVAL_SECONDS > now:
            return
        _stamp_written[unit] = now
        try:
            path = stamp_path(unit)
            with open(path, "a"):
                pass
            os.utime(path, None)
        except OSError:
            pass


    def port_open(port, timeout=0.5):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout):
                return True
        except OSError:
            return False


    def unit_active(unit):
        try:
            return subprocess.run(["systemctl", "is-active", "--quiet", unit]).returncode == 0
        except OSError:
            return False


    def start_unit(unit):
        try:
            subprocess.run(["systemctl", "start", unit], timeout=60)
        except (OSError, subprocess.SubprocessError):
            pass


    def wait_for_port(port, deadline):
        while time.time() < deadline:
            if port_open(port):
                return True
            time.sleep(0.2)
        return port_open(port)


    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            parsed = urlparse(self.path)
            params = parse_qs(parsed.query)
            unit = (params.get("unit") or [""])[0]
            port = (params.get("port") or [""])[0]

            if parsed.path == "/health":
                return self.reply(200, "ok")
            if parsed.path != "/wake":
                return self.reply(404, "not found")
            if not UNIT_PATTERN.match(unit) or not port.isdigit():
                return self.reply(400, "invalid request")

            port = int(port)
            # Only units the panel armed can be started, so a local process
            # cannot use this service to launch arbitrary units.
            if not 0 < port < 65536 or not os.path.exists(stamp_path(unit)):
                return self.reply(403, "unit is not managed by cleat")

            touch_stamp(unit)

            # Fast path: the app is already listening, nothing to do.
            if port_open(port):
                return self.reply(200, "awake")

            with unit_lock(unit):
                if not port_open(port):
                    if not unit_active(unit):
                        start_unit(unit)
                    wait_for_port(port, time.time() + PORT_WAIT_SECONDS)

            if port_open(port):
                self.reply(200, "awake")
            else:
                self.reply(503, "app did not become ready")

        def reply(self, code, message):
            body = (message + "\\n").encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass


    def main():
        os.makedirs(STAMP_DIR, exist_ok=True)
        server = ThreadingHTTPServer((LISTEN_ADDRESS, LISTEN_PORT), Handler)
        server.daemon_threads = True
        server.serve_forever()


    if __name__ == "__main__":
        main()
    """
  end

  defp waker_unit_file do
    """
    [Unit]
    Description=Cleat wake agent (starts apps on the first request after sleep)
    After=network.target

    [Service]
    Type=simple
    User=root
    ExecStart=/usr/bin/python3 #{@waker_path}
    Restart=always
    RestartSec=2
    MemoryMax=64M
    NoNewPrivileges=true

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp sh_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
