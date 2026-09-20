defmodule CleatDeploy.Servers.HostStatsTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Servers.HostStats

  @stat_a """
  cpu  100 0 50 850 0 0 0 0
  cpu0 100 0 50 850 0 0 0 0
  """

  @stat_b """
  cpu  140 0 70 890 0 0 0 0
  cpu0 140 0 70 890 0 0 0 0
  """

  @net_a """
  Inter-|   Receive                                                |  Transmit
   face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
      lo: 9999 0 0 0 0 0 0 0 9999 0 0 0 0 0 0 0
    eth0: 1000 1 0 0 0 0 0 0 500 1 0 0 0 0 0 0
  veth0: 8000 1 0 0 0 0 0 0 8000 1 0 0 0 0 0 0
  """

  @net_b """
  Inter-|   Receive                                                |  Transmit
   face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
      lo: 19999 0 0 0 0 0 0 0 19999 0 0 0 0 0 0 0
    eth0: 6000 2 0 0 0 0 0 0 2500 2 0 0 0 0 0 0
  veth0: 18000 2 0 0 0 0 0 0 18000 2 0 0 0 0 0 0
  """

  test "cpu_pct uses 100% per vCPU like Hetzner" do
    {:ok, a} = HostStats.parse_cpu(@stat_a)
    {:ok, b} = HostStats.parse_cpu(@stat_b)

    # delta total 100, idle 40 → 60% of the box × 4 vCPU = 240%
    assert HostStats.cpu_pct(a, b, 4) == 240.0
  end

  test "parse_net ignores loopback and veth" do
    {:ok, a} = HostStats.parse_net(@net_a)
    {:ok, b} = HostStats.parse_net(@net_b)
    assert a == %{in: 1000, out: 500}
    assert b == %{in: 6000, out: 2500}
  end

  test "diff returns hetzner-scale cpu and bytes/s" do
    {:ok, cpu_a} = HostStats.parse_cpu(@stat_a)
    {:ok, cpu_b} = HostStats.parse_cpu(@stat_b)
    {:ok, net_a} = HostStats.parse_net(@net_a)
    {:ok, net_b} = HostStats.parse_net(@net_b)

    stats =
      HostStats.diff(
        %{cpu: cpu_a, net: net_a, at: 0},
        %{cpu: cpu_b, net: net_b, at: 5_000},
        4
      )

    assert stats.cpu_pct == 240.0
    assert_in_delta stats.net_in, 1000.0, 0.01
    assert_in_delta stats.net_out, 400.0, 0.01
  end

  test "local? is false for remote server ips" do
    refute HostStats.local?(%{host_ip: "10.0.0.1"})
    refute HostStats.local?(nil)
    assert HostStats.local?(%{host_ip: "127.0.0.1"})
  end

  @df """
  Filesystem     1024-blocks     Used Available Capacity Mounted on
  /dev/sda1         78397936 67004240   8176812      90% /
  """

  test "parse_df returns used/total and df's capacity percentage" do
    usage = HostStats.parse_df(@df)

    assert usage.total == 78_397_936 * 1024
    assert usage.used == 67_004_240 * 1024
    # df's Capacity column: used/(used+avail), excluding reserved blocks.
    assert usage.pct == 90.0
  end

  test "parse_df is nil on unparseable output" do
    assert HostStats.parse_df("") == nil

    assert HostStats.parse_df("Filesystem 1024-blocks Used Available Capacity Mounted on\n") ==
             nil
  end

  @meminfo """
  MemTotal:        7937232 kB
  MemFree:         1223156 kB
  MemAvailable:    5978488 kB
  """

  test "parse_meminfo returns used/total/pct" do
    usage = HostStats.parse_meminfo(@meminfo)

    assert usage.total == 7_937_232 * 1024
    assert usage.used == (7_937_232 - 5_978_488) * 1024
    assert usage.pct == 25.0
  end

  test "parse_meminfo is nil without the needed keys" do
    assert HostStats.parse_meminfo("MemFree: 10 kB\n") == nil
  end
end
