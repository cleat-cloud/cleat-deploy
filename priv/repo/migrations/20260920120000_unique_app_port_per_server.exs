defmodule CleatDeploy.Repo.Migrations.UniqueAppPortPerServer do
  use Ecto.Migration

  import Ecto.Query

  # Two apps on the same server cannot listen on the same port: the second
  # process dies with EADDRINUSE. Reassign existing duplicates to free ports,
  # then enforce uniqueness so a bad allocation can never be persisted again.
  def up do
    dedupe_ports()
    create unique_index(:apps, [:server_id, :port])
  end

  def down do
    drop unique_index(:apps, [:server_id, :port])
  end

  defp dedupe_ports do
    rows =
      repo().all(
        from(a in "apps",
          select: {a.id, a.server_id, a.port},
          order_by: [asc: a.server_id, asc: a.id]
        )
      )

    {_used, reassignments} =
      Enum.reduce(rows, {%{}, []}, fn {id, server_id, port}, {used_by_server, reassignments} ->
        used = Map.get(used_by_server, server_id, MapSet.new())

        if is_integer(port) and not MapSet.member?(used, port) do
          {Map.put(used_by_server, server_id, MapSet.put(used, port)), reassignments}
        else
          free = Enum.find(4000..32_767, &(&1 not in used and &1 != panel_port()))

          {Map.put(used_by_server, server_id, MapSet.put(used, free)),
           [{id, free} | reassignments]}
        end
      end)

    Enum.each(reassignments, fn {id, port} ->
      repo().query!("UPDATE apps SET port = ? WHERE id = ?", [port, id])
    end)
  end

  # The panel listens on the host's PORT env var; keep it out of the pool.
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
end
