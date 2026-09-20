defmodule CleatDeploy.Deploy.Runtime do
  @moduledoc false

  alias CleatDeploy.Apps.App

  def kind(_repo_path, %App{runtime: "golang"}), do: :golang
  def kind(_repo_path, %App{runtime: "node"}), do: :node

  def kind(repo_path, %App{}) when is_binary(repo_path) do
    go? = File.exists?(Path.join(repo_path, "go.mod"))
    mix? = File.exists?(Path.join(repo_path, "mix.exs"))

    cond do
      go? and not mix? -> :golang
      true -> :phoenix
    end
  end

  def kind(_repo_path, %App{}), do: :phoenix
end
