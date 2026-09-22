defmodule CleatDeploy.Servers.Provision do
  @moduledoc false

  import Ecto.Changeset

  alias CleatDeploy.Hetzner.Catalog

  @types %{
    name: :string,
    region: :string,
    bundle_id: :string,
    deploy_mode: :string,
    provider: :string
  }

  @locations [
    {"Falkenstein (fsn1)", "fsn1"},
    {"Nuremberg (nbg1)", "nbg1"},
    {"Helsinki (hel1)", "hel1"}
  ]

  def changeset(attrs \\ %{}) do
    {%{}, @types}
    |> cast(stringify(attrs), Map.keys(@types))
    |> validate_required([:name, :region, :bundle_id, :deploy_mode])
    |> update_change(:name, &normalize_name/1)
    |> validate_format(:name, ~r/^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$/,
      message: "use lowercase letters, numbers, and dashes"
    )
    |> validate_inclusion(:region, ~w(fsn1 nbg1 hel1))
    |> validate_inclusion(:bundle_id, Enum.map(Catalog.all_bundles(), & &1.bundle_id))
    |> validate_inclusion(:deploy_mode, ~w(shared dedicated))
    |> put_change(:provider, "hetzner")
  end

  def locations, do: @locations

  def bundles, do: Catalog.all_bundles()

  def defaults do
    %{
      "name" => "",
      "region" => "fsn1",
      "bundle_id" => "cx33",
      "deploy_mode" => "shared",
      "provider" => "hetzner"
    }
  end

  def user_data(public_key) when is_binary(public_key) do
    """
    #cloud-config
    users:
      - name: ubuntu
        sudo: ALL=(ALL) NOPASSWD:ALL
        groups: sudo
        shell: /bin/bash
        ssh_authorized_keys:
          - #{String.trim(public_key)}
    package_update: true
    packages:
      - curl
      - git
      - build-essential
      - ufw
    runcmd:
      - [ufw, allow, OpenSSH]
      - [ufw, allow, 80/tcp]
      - [ufw, allow, 443/tcp]
      # Caddy serves HTTP/3 on UDP 443 and advertises it with `alt-svc`; a
      # browser that takes the offer against a closed port fails the page with
      # ERR_SSL_PROTOCOL_ERROR even though TCP works.
      - [ufw, allow, 443/udp]
      - [ufw, --force, enable]
    """
  end

  defp normalize_name(nil), do: nil

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.trim("-")
  end

  defp stringify(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
