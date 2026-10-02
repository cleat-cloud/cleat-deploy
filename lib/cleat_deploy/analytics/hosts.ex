defmodule CleatDeploy.Analytics.Hosts do
  @moduledoc false
  import Ecto.Query
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Repo

  def payload(server_id) when is_integer(server_id) do
    from(a in App,
      where: a.server_id == ^server_id and a.analytics_inject == true,
      select: {a.host, a.slug, a.port}
    )
    |> Repo.all()
    |> Map.new(fn {host, slug, port} ->
      {host, %{"slug" => slug, "upstream" => "127.0.0.1:#{port}"}}
    end)
  end
end
