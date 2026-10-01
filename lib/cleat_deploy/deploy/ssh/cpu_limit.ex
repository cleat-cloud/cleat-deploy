defmodule CleatDeploy.Deploy.Ssh.CpuLimit do
  @moduledoc false

  # 150% = 1.5 vCPU. Hetzner reports 100% per vCPU, so a CX33 (4 vCPU) saturates
  # near 400%. One unthrottled `mix compile` already hits ~330% and starves
  # Caddy/sshd; the quota leaves headroom for :443/:22.
  def snippet do
    ~S"""
    cleat_cpu_limit() {
      if command -v systemd-run >/dev/null 2>&1; then
        envfile=$(mktemp)
        env | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' > "$envfile"
        sudo systemd-run --quiet --uid="$(id -u)" --gid="$(id -g)" --wait --pipe --collect \
          -p CPUQuota=150% -p Nice=10 -p "EnvironmentFile=$envfile" \
          --working-directory="$PWD" -- "$@"
        st=$?; rm -f "$envfile"; return $st
      fi
      nice -n 10 "$@"
    }
    """
  end

  def wrap(cmd) when is_binary(cmd), do: "cleat_cpu_limit #{cmd}"
end
