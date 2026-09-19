defmodule CleatDeploy.Accounts.ApiToken do
  @moduledoc """
  Personal access token used by the `cleat` CLI to talk to the JSON API.

  The raw token is shown once at creation time; only its SHA-256 hash is
  persisted, so a leaked database cannot be replayed against the API.
  """

  use Ecto.Schema
  import Ecto.Query

  alias CleatDeploy.Accounts.{Tenant, User}

  @hash_algorithm :sha256
  @rand_size 32
  @prefix "cleat_"

  schema "api_tokens" do
    field :name, :string, default: "default"
    field :token, :binary, redact: true
    field :last_used_at, :utc_datetime

    belongs_to :user, User
    belongs_to :tenant, Tenant

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a raw token and its persisted (hashed) struct for a user/tenant.
  """
  def build(%User{id: user_id}, %Tenant{id: tenant_id}, name) do
    raw = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@rand_size), padding: false)

    {raw,
     %__MODULE__{
       user_id: user_id,
       tenant_id: tenant_id,
       name: normalize_name(name),
       token: hash(raw)
     }}
  end

  @doc """
  Hashes a raw token the same way tokens are persisted.
  """
  def hash(raw) when is_binary(raw), do: :crypto.hash(@hash_algorithm, raw)

  @doc """
  Query matching a raw token against the stored hash.
  """
  def verify_query(raw) when is_binary(raw) do
    from t in __MODULE__, where: t.token == ^hash(raw)
  end

  defp normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> "default"
      trimmed -> trimmed
    end
  end

  defp normalize_name(_), do: "default"
end
