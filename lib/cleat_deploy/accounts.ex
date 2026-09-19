defmodule CleatDeploy.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias CleatDeploy.Repo

  alias CleatDeploy.Accounts.{
    ApiToken,
    Scope,
    Tenant,
    TenantMembership,
    User,
    UserNotifier,
    UserToken
  }

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  def get_user(id), do: Repo.get(User, id)

  defp tenant_name_from_email(email) when is_binary(email) do
    email
    |> String.split("@")
    |> hd()
    |> String.replace(".", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp tenant_slug_from_email(email) when is_binary(email) do
    email
    |> String.split("@")
    |> hd()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers a user and creates their default tenant (owner membership).
  """
  def change_user_registration(user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(user, attrs, opts)
  end

  def register_user_with_tenant(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Ecto.Multi.run(:tenant, fn _repo, %{user: user} ->
      tenant_attrs = %{
        name: tenant_name_from_email(user.email),
        slug: tenant_slug_from_email(user.email)
      }

      %Tenant{}
      |> Tenant.changeset(tenant_attrs)
      |> Repo.insert()
    end)
    |> Ecto.Multi.insert(:membership, fn %{user: user, tenant: tenant} ->
      TenantMembership.changeset(%TenantMembership{}, %{
        user_id: user.id,
        tenant_id: tenant.id,
        role: "owner"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, tenant: tenant, membership: membership}} ->
        {:ok, %{user: user, tenant: tenant, membership: membership}}

      {:error, :user, changeset, _} ->
        {:error, changeset}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Returns the active scope for a user (first tenant membership).
  """
  def get_scope_for_user(%User{} = user) do
    case Repo.one(
           from m in TenantMembership,
             where: m.user_id == ^user.id,
             order_by: [desc: m.id],
             limit: 1,
             preload: [:tenant]
         ) do
      %TenantMembership{tenant: tenant, role: role} ->
        Scope.for_user(user, tenant, role)

      nil ->
        nil
    end
  end

  def get_scope_for_user(nil), do: nil

  @doc """
  Returns the user's scope, creating a default tenant when none exists yet.
  """
  def ensure_scope_for_user(%User{} = user) do
    case get_scope_for_user(user) do
      %Scope{} = scope ->
        scope

      nil ->
        ensure_tenant_for_user(user, %{
          name: tenant_name_from_email(user.email),
          slug: tenant_slug_from_email(user.email)
        })
    end
  end

  def ensure_scope_for_user(nil), do: nil

  @doc """
  Upserts a tenant by slug and ensures the user has an owner membership.
  """
  def ensure_tenant_for_user(%User{} = user, %{name: name, slug: slug}) do
    tenant =
      case Repo.get_by(Tenant, slug: slug) do
        %Tenant{} = existing -> existing
        nil -> Repo.insert!(Tenant.changeset(%Tenant{}, %{name: name, slug: slug}))
      end

    %TenantMembership{}
    |> TenantMembership.changeset(%{user_id: user.id, tenant_id: tenant.id, role: "owner"})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :tenant_id]
    )

    Scope.for_user(user, tenant, "owner")
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `CleatDeploy.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `CleatDeploy.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs, opts \\ []) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens(opts)
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    token = normalize_session_token(token)

    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc false
  def normalize_session_token(token) when is_binary(token) do
    if byte_size(token) == 32 do
      token
    else
      case Base.url_decode64(token, padding: false) do
        {:ok, decoded} when byte_size(decoded) == 32 -> decoded
        _ -> token
      end
    end
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    token = normalize_session_token(token)
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## API tokens

  @doc """
  Creates a personal access token for the user in the given tenant.

  Returns `{:ok, raw_token, %ApiToken{}}`. The raw token is only returned here
  and never stored, so it cannot be recovered later.
  """
  def create_api_token(%User{} = user, %Tenant{} = tenant, attrs \\ %{}) do
    name = attrs |> Map.new() |> string_key_get("name")

    {raw, token} = ApiToken.build(user, tenant, name)

    case Repo.insert(token) do
      {:ok, token} -> {:ok, raw, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Lists the user's personal access tokens (without the raw value).
  """
  def list_api_tokens(%User{} = user) do
    Repo.all(
      from t in ApiToken,
        where: t.user_id == ^user.id,
        order_by: [desc: t.inserted_at, desc: t.id]
    )
  end

  @doc """
  Revokes one of the user's tokens. Returns `:ok` or `{:error, :not_found}`.
  """
  def revoke_api_token(%User{} = user, id) do
    case Repo.get_by(ApiToken, id: id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      token ->
        case Repo.delete(token) do
          {:ok, _} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Resolves a raw bearer token to `{%Scope{}, %ApiToken{}}`.

  Returns `nil` when the token is unknown, revoked, or the user no longer
  belongs to the token's tenant. Touches `last_used_at` on success.
  """
  def get_scope_by_api_token(raw) when is_binary(raw) do
    case Repo.one(ApiToken.verify_query(raw)) do
      nil ->
        nil

      %ApiToken{} = token ->
        with %User{} = user <- Repo.get(User, token.user_id),
             %Tenant{} = tenant <- Repo.get(Tenant, token.tenant_id),
             role when is_binary(role) <- membership_role(user.id, tenant.id) do
          _ = touch_api_token(token)
          {Scope.for_user(user, tenant, role), token}
        else
          _ -> nil
        end
    end
  end

  def get_scope_by_api_token(_), do: nil

  defp membership_role(user_id, tenant_id) do
    Repo.one(
      from m in TenantMembership,
        where: m.user_id == ^user_id and m.tenant_id == ^tenant_id,
        select: m.role
    )
  end

  defp touch_api_token(%ApiToken{id: id}) do
    Repo.update_all(
      from(t in ApiToken, where: t.id == ^id),
      set: [last_used_at: DateTime.utc_now(:second)]
    )
  end

  defp string_key_get(map, key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset, opts \\ []) do
    keep_token =
      opts
      |> Keyword.get(:keep_session_token)
      |> keep_session_token()

    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        {tokens_to_keep, tokens_to_delete} =
          Enum.split_with(tokens_to_expire, &keep_session_token?(&1, keep_token))

        if keep_token && tokens_to_keep != [] do
          now = DateTime.utc_now(:second)

          Repo.update_all(
            from(t in UserToken, where: t.id in ^Enum.map(tokens_to_keep, & &1.id)),
            set: [authenticated_at: now]
          )
        end

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_delete, & &1.id)))

        # Password changes and email confirmations invalidate API tokens too, so
        # a leaked CLI token cannot outlive the credentials that created it.
        _ = Repo.delete_all(from(t in ApiToken, where: t.user_id == ^user.id))

        {:ok, {user, tokens_to_delete}}
      end
    end)
  end

  defp keep_session_token(nil), do: nil

  defp keep_session_token(token) when is_binary(token) do
    normalize_session_token(token)
  end

  defp keep_session_token?(_token, nil), do: false

  defp keep_session_token?(%UserToken{token: token, context: "session"}, keep_token) do
    token == keep_token
  end

  defp keep_session_token?(_token, _keep_token), do: false
end
