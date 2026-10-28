defmodule CleatDeploy.Deploy.Provision.Static do
  @moduledoc false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.Provision.{Caddy, Shell, WakeAgent}

  def provision_script(%App{} = app, config, %AppManifest{} = manifest) do
    caddy_script = Caddy.provision_script(app, config, manifest)
    wake_script = WakeAgent.script(app, config, manifest)

    """
    log "Provisioning static site #{app.host}"
    sudo mkdir -p #{Shell.shell_escape(config.release_path)}

    #{wake_script}
    #{caddy_script}
    """
  end
end
