defmodule CleatDeployWeb.PaasComponents do
  @moduledoc false

  alias CleatDeployWeb.PaasComponents.RepoPicker

  defdelegate filter_repo_options(repos, query), to: RepoPicker
  defdelegate filter_repo_options(repos, query, limit), to: RepoPicker
  defdelegate count_repo_matches(repos, query), to: RepoPicker
end
