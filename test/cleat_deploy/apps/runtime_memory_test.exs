defmodule CleatDeploy.Apps.RuntimeMemoryTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps.RuntimeMemory
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    %{scope: scope, server: server}
  end

  test "reads cgroup memory, cpu, and disk for a phoenix unit", %{scope: scope, server: server} do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "open-drive",
        systemd_unit: "open_drive",
        runtime: "phoenix",
        release_path: "/opt/open_drive"
      })

    stats = RuntimeMemory.for_app(app)

    assert stats.bytes == 171_200_512
    assert stats.peak_bytes == 187_977_728
    assert stats.cpu_pct == 2.8
    assert stats.disk_bytes == 524_288_000 + 10_485_760
    assert stats.active?

    assert RuntimeMemory.format(stats) == "163 MB"
    assert RuntimeMemory.format_cpu(stats) == "2.8%"
    assert RuntimeMemory.format_disk(stats) == "510 MB"
  end

  test "sums golang server and worker units", %{scope: scope, server: server} do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "github-projects",
        systemd_unit: "github-projects",
        runtime: "golang",
        release_path: "/opt/github-projects"
      })

    memory = RuntimeMemory.for_app(app)
    assert memory.bytes == 171_200_512 + 10_416_128
    assert memory.cpu_pct == 4.5
    assert memory.disk_bytes == 524_288_000
    assert memory.active?
    assert RuntimeMemory.format(memory) == "173 MB"
    assert RuntimeMemory.format_peak(memory) == "Peak 205 MB"
    assert RuntimeMemory.format_cpu(memory) == "4.5%"
    assert RuntimeMemory.format_disk(memory) == "500 MB"
  end

  test "a hibernated go app reads as stopped even with its worker running", %{
    scope: scope,
    server: server
  } do
    previous = Application.get_env(:cleat_deploy, :runtime_memory)
    Application.put_env(:cleat_deploy, :runtime_memory, CleatDeploy.Apps.RuntimeMemoryStoppedStub)

    on_exit(fn ->
      if previous, do: Application.put_env(:cleat_deploy, :runtime_memory, previous)
    end)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "sleeper",
        systemd_unit: "phx-sleeper",
        runtime: "golang",
        release_path: "/opt/sleeper"
      })

    memory = RuntimeMemory.for_app(app)

    refute memory.active?
    assert RuntimeMemory.format_status(memory) == "Stopped"
  end

  test "probe_async/3 answers by message instead of blocking the caller", %{
    scope: scope,
    server: server
  } do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "open-drive",
        systemd_unit: "open_drive",
        release_path: "/opt/open_drive"
      })

    ref = make_ref()

    assert {:ok, pid} = RuntimeMemory.probe_async(self(), ref, app)
    assert is_pid(pid)
    refute pid == self()

    assert_receive {:app_memory, ^ref, memory}, 2_000
    assert memory.bytes == 171_200_512
  end

  test "probe_async/3 reports live stats before disk finishes", %{
    scope: scope,
    server: server
  } do
    previous = Application.get_env(:cleat_deploy, :runtime_memory)

    Application.put_env(
      :cleat_deploy,
      :runtime_memory,
      CleatDeploy.Apps.RuntimeMemorySlowDiskStub
    )

    on_exit(fn ->
      if previous, do: Application.put_env(:cleat_deploy, :runtime_memory, previous)
    end)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "open-drive",
        systemd_unit: "open_drive",
        release_path: "/opt/open_drive"
      })

    ref = make_ref()
    started = System.monotonic_time(:millisecond)

    assert {:ok, _pid} = RuntimeMemory.probe_async(self(), ref, app)

    assert_receive {:app_memory, ^ref, live}, 400
    assert System.monotonic_time(:millisecond) - started < 400
    assert live.bytes == 171_200_512
    assert live.cpu_pct == 2.8
    assert live.active?
    assert live.disk_bytes == nil

    assert_receive {:app_memory, ^ref, complete}, 2_000
    assert complete.bytes == 171_200_512
    assert complete.disk_bytes == 524_288_000 + 10_485_760
  end

  test "probes every unit recorded by the last deploy", %{scope: scope, server: server} do
    previous = Application.get_env(:cleat_deploy, :runtime_memory)
    Application.put_env(:cleat_deploy, :runtime_memory, CleatDeploy.Apps.RuntimeMemoryStoppedStub)

    on_exit(fn ->
      if previous, do: Application.put_env(:cleat_deploy, :runtime_memory, previous)
    end)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "multi",
        systemd_unit: "phx-sleeper",
        runtime: "rails",
        release_path: "/opt/multi"
      })
      |> Map.put(:deploy_manifest, %{"units" => ["worker"], "addons" => []})

    memory = RuntimeMemory.for_app(app)

    # The worker's memory is summed in, but liveness comes from the web unit.
    assert memory.bytes == 10_416_128
    refute memory.active?
  end

  test "skips unsafe systemd unit names", %{scope: scope, server: server} do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "evil",
        systemd_unit: "atelie; rm -rf /"
      })

    assert RuntimeMemory.for_app(app) == nil
  end

  test "format_bytes uses one decimal under 10 MB and GB above 1 GB" do
    assert RuntimeMemory.format_bytes(5_505_024) == "5.3 MB"
    assert RuntimeMemory.format_bytes(171_200_512) == "163 MB"
    assert RuntimeMemory.format_bytes(2_147_483_648) == "2.0 GB"
    assert RuntimeMemory.format(nil) == "—"
    assert RuntimeMemory.format_cpu(nil) == "—"
    assert RuntimeMemory.format_disk(nil) == "—"
  end
end
