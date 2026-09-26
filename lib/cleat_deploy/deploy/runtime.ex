defmodule CleatDeploy.Deploy.Runtime do
  @moduledoc false

  alias CleatDeploy.Apps.App

  def kind(_repo_path, %App{runtime: "golang"}), do: :golang
  def kind(_repo_path, %App{runtime: "node"}), do: :node
  def kind(_repo_path, %App{runtime: "rails"}), do: :rails
  def kind(_repo_path, %App{runtime: "rust"}), do: :rust
  def kind(_repo_path, %App{runtime: "gleam"}), do: :gleam

  def kind(repo_path, %App{}) when is_binary(repo_path) do
    go? = File.exists?(Path.join(repo_path, "go.mod"))
    mix? = File.exists?(Path.join(repo_path, "mix.exs"))
    rust? = File.exists?(Path.join(repo_path, "Cargo.toml"))
    gleam? = File.exists?(Path.join(repo_path, "gleam.toml"))

    rails? =
      File.exists?(Path.join(repo_path, "Gemfile")) and
        File.exists?(Path.join(repo_path, "config/application.rb"))

    cond do
      go? and not mix? -> :golang
      rails? and not mix? -> :rails
      rust? and not mix? -> :rust
      gleam? and not mix? -> :gleam
      true -> :phoenix
    end
  end

  def kind(_repo_path, %App{}), do: :phoenix
end
