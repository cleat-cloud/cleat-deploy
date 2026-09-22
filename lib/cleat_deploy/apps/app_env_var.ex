defmodule CleatDeploy.Apps.AppEnvVar do
  @moduledoc """
  An environment variable of an app, scoped to a branch.

  `branch == "*"` means the variable applies to every deploy, whatever branch it
  runs; any other value is the branch name the variable is restricted to. A
  deploy of branch `X` receives the `"*"` variables overridden by the ones
  scoped to `X`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Encrypted

  @all_branches "*"
  @all_branches_labels ["*", "all branches", "all-branches"]

  schema "app_env_vars" do
    field :key, :string
    field :value, Encrypted.Binary
    field :branch, :string, default: @all_branches

    belongs_to :app, App

    timestamps(type: :utc_datetime)
  end

  def all_branches, do: @all_branches

  def all_branches?(branch), do: normalize(branch) == @all_branches

  @doc """
  Whether a variable scoped to `scope` is part of the environment of `branch`.
  """
  def applies_to?(scope, branch), do: all_branches?(scope) or scope == branch

  @doc """
  Normalizes a branch scope: blanks and the "all branches" spellings become `"*"`.
  """
  def normalize(branch) when is_binary(branch) do
    normalized =
      branch
      |> String.trim()
      |> String.replace_prefix("refs/heads/", "")

    if normalized == "" or String.downcase(normalized) in @all_branches_labels do
      @all_branches
    else
      normalized
    end
  end

  def normalize(nil), do: @all_branches

  def changeset(env_var, attrs) do
    env_var
    |> cast(attrs, [:key, :value, :app_id, :branch])
    |> normalize_branch()
    |> validate_required([:key, :value, :app_id, :branch])
    |> validate_format(:key, ~r/^[A-Z][A-Z0-9_]*$/, message: "must be UPPER_SNAKE_CASE")
    |> validate_format(:branch, ~r/^(\*|(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9._\/-]*)$/,
      message: "must be a git branch name or all branches"
    )
    |> unique_constraint([:app_id, :key, :branch])
    |> foreign_key_constraint(:app_id)
  end

  defp normalize_branch(changeset) do
    case fetch_change(changeset, :branch) do
      {:ok, branch} -> put_change(changeset, :branch, normalize(branch))
      :error -> changeset
    end
  end
end
