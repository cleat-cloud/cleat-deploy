defmodule CleatDeploy.Apps.Ports do
  @moduledoc """
  Port allocation for apps sharing a server.
  """

  import Ecto.Query, warn: false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Repo

  # Ports handed out to apps. Kept below the Linux ephemeral range
  # (32768-60999) so an app never fights with an outgoing connection.
  @port_range 4000..32_767

  @doc """
  Returns a port that is free on `server_id`.

  `preferred` is kept when it is already free; otherwise the lowest free port in
  `#{inspect(@port_range)}` is used. This prevents a new app from being assigned
  a port already bound by another app on the same server (EADDRINUSE).
  """
  def allocate_port(server_id, preferred \\ nil) when is_integer(server_id) do
    used = used_ports(server_id)

    if is_integer(preferred) and preferred in @port_range and preferred not in used do
      preferred
    else
      Enum.find(@port_range, &(&1 not in used))
    end
  end

  @doc "Puts a free port into the app attributes when they carry a server."
  def assign_free_port(%{"server_id" => server_id} = attrs) do
    case to_integer(server_id) do
      nil -> attrs
      id -> Map.put(attrs, "port", allocate_port(id, to_integer(attrs["port"])))
    end
  end

  def assign_free_port(attrs), do: attrs

  defp used_ports(server_id) do
    from(a in App, where: a.server_id == ^server_id, select: a.port)
    |> Repo.all()
    |> MapSet.new()
    |> MapSet.put(panel_port())
  end

  # The panel itself listens on this host's PORT; it is not in the apps table
  # and must never be handed out to an app.
  defp panel_port do
    case System.get_env("PORT") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {port, ""} -> port
          _ -> nil
        end
    end
  end

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_integer(_value), do: nil
end
