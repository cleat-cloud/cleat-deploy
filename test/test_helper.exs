ExUnit.start(exclude: [integration: true])
Ecto.Adapters.SQL.Sandbox.mode(CleatDeploy.Repo, :manual)

Mox.defmock(CleatDeploy.Deploy.RunnerMock, for: CleatDeploy.Deploy.Runner)
Mox.defmock(CleatDeploy.AWS.LightsailMock, for: CleatDeploy.AWS.Lightsail)
Mox.defmock(CleatDeploy.HetznerMock, for: CleatDeploy.Hetzner)
Mox.defmock(CleatDeploy.Deploy.DnsMock, for: CleatDeploy.Deploy.DnsResolver)
Mox.defmock(CleatDeploy.Apps.RuntimeLogsMock, for: CleatDeploy.Apps.RuntimeLogs)
