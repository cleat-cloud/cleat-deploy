defmodule CleatDeploy.Deploy.AnalyticsProvision do
  @moduledoc """
  Provisions the per-VPS analytics sidecar: python, systemd unit, hosts JSON, salt.

  The site must stay up if the unit is down (Caddy fails over to the app), so
  install never exits 1 when the sidecar does not listen.
  """

  alias CleatDeploy.Analytics.Hosts
  alias CleatDeploy.Apps.App

  @unit "cleat-analytics"
  @python_path "/usr/local/lib/cleat/cleat_analytics.py"
  @hosts_path "/etc/cleat/analytics-hosts.json"
  @salt_path "/etc/cleat/analytics.salt"

  @doc """
  Installs or refreshes the sidecar on the host.

  Hosts JSON is always rewritten when `server_id` is set, including `{}` on the
  last inject-off so a disabled host disappears. Python and the systemd unit
  are installed only when this app is inject-on or another inject-on app still
  lives on the server — a first-time generic static drop must not enable a
  crashing placeholder unit.
  """
  def install_script(%App{} = app) do
    payload = hosts_payload(app)
    install_unit? = app.analytics_inject == true or payload != %{}

    cond do
      install_unit? -> render_install_script(payload)
      is_integer(app.server_id) -> render_hosts_script(payload)
      true -> ""
    end
  end

  defp hosts_payload(%App{server_id: server_id}) when is_integer(server_id) do
    Hosts.payload(server_id)
  end

  defp hosts_payload(%App{}), do: %{}

  defp render_install_script(payload) do
    """
    log "Installing analytics sidecar (#{@unit})"
    sudo mkdir -p /usr/local/lib/cleat /etc/cleat

    if [ ! -f #{@salt_path} ]; then
      dd if=/dev/urandom of=/tmp/cleat_analytics.salt bs=32 count=1
      sudo install -m 0644 -o root -g root /tmp/cleat_analytics.salt #{@salt_path}
      rm -f /tmp/cleat_analytics.salt
    fi

    cat > /tmp/cleat_analytics.py <<'CLEAT_ANALYTICS_PY'
    #{String.trim_trailing(python_script())}
    CLEAT_ANALYTICS_PY

    cat > /tmp/cleat_analytics.service <<'CLEAT_ANALYTICS_UNIT'
    #{String.trim_trailing(unit_file())}
    CLEAT_ANALYTICS_UNIT

    #{hosts_heredoc(payload)}

    PY_CHANGED=0
    if ! sudo cmp -s /tmp/cleat_analytics.py #{@python_path}; then PY_CHANGED=1; fi
    UNIT_CHANGED=0
    if ! sudo cmp -s /tmp/cleat_analytics.service /etc/systemd/system/#{@unit}.service; then UNIT_CHANGED=1; fi

    sudo install -m 0755 -o root -g root /tmp/cleat_analytics.py #{@python_path}
    sudo install -m 0644 -o root -g root /tmp/cleat_analytics.service /etc/systemd/system/#{@unit}.service
    sudo install -m 0644 -o root -g root /tmp/cleat_analytics_hosts.json #{@hosts_path}
    rm -f /tmp/cleat_analytics.py /tmp/cleat_analytics.service /tmp/cleat_analytics_hosts.json

    sudo systemctl daemon-reload || true
    sudo systemctl enable #{@unit} > /dev/null 2>&1 || true

    if [ "$PY_CHANGED" = "1" ] || [ "$UNIT_CHANGED" = "1" ]; then
      sudo systemctl restart #{@unit} || true
    else
      sudo systemctl start #{@unit} 2>/dev/null || true
    fi
    """
    |> String.trim()
  end

  defp render_hosts_script(payload) do
    """
    log "Refreshing analytics hosts"
    sudo mkdir -p /etc/cleat

    #{hosts_heredoc(payload)}

    sudo install -m 0644 -o root -g root /tmp/cleat_analytics_hosts.json #{@hosts_path}
    rm -f /tmp/cleat_analytics_hosts.json
    """
    |> String.trim()
  end

  defp hosts_heredoc(payload) do
    """
    cat > /tmp/cleat_analytics_hosts.json <<'CLEAT_ANALYTICS_HOSTS'
    #{Jason.encode!(payload)}
    CLEAT_ANALYTICS_HOSTS
    """
    |> String.trim()
  end

  defp python_script do
    File.read!(Application.app_dir(:cleat_deploy, "priv/analytics/cleat_analytics.py"))
  end

  defp unit_file do
    """
    [Unit]
    Description=Cleat analytics sidecar
    After=network.target

    [Service]
    Type=simple
    DynamicUser=yes
    StateDirectory=cleat-analytics
    Nice=10
    CPUQuota=20%
    MemoryMax=64M
    Restart=always
    RestartSec=2
    Environment=CLEAT_ANALYTICS_HOSTS=/etc/cleat/analytics-hosts.json
    Environment=CLEAT_ANALYTICS_SALT=/etc/cleat/analytics.salt
    ExecStart=/usr/bin/python3 /usr/local/lib/cleat/cleat_analytics.py
    AmbientCapabilities=
    RestrictAddressFamilies=AF_INET AF_UNIX
    IPAddressDeny=any
    IPAddressAllow=127.0.0.1
    # Salt and hosts are 0644 so DynamicUser can read them (640 root:root
    # is unreadable). HMAC salt is not a password; 0644 on a locked-down
    # VPS is acceptable.

    [Install]
    WantedBy=multi-user.target
    """
  end
end
