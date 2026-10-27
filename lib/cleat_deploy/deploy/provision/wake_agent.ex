defmodule CleatDeploy.Deploy.Provision.WakeAgent do
  @moduledoc """
  Installs (or disarms) the idle-shutdown wake agent for an app.
  """

  alias CleatDeploy.Deploy.{AppManifest, Wake}

  @doc """
  Installs the wake agent for opted-in apps. Apps that are not armed get their
  stamp removed, so the sweeper never stops something that cannot be woken
  again.
  """
  def script(app, config, %AppManifest{} = manifest) do
    if Wake.enabled?(app, manifest) do
      Wake.install_script(config.systemd_unit)
    else
      Wake.disarm_script(config.systemd_unit)
    end
  end
end
