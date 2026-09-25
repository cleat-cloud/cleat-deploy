defmodule CleatDeploy.Repo.Migrations.EncryptAppWebhookSecrets do
  use Ecto.Migration

  import Ecto.Query

  def up do
    with_vault(fn ->
      rows =
        repo().all(from(a in "apps", select: %{id: a.id, webhook_secret: a.webhook_secret}))

      Enum.each(rows, fn %{id: id, webhook_secret: secret} ->
        case encrypt_secret(secret) do
          {:ok, ^secret} ->
            :ok

          {:ok, ciphertext} ->
            repo().update_all(from(a in "apps", where: a.id == ^id),
              set: [webhook_secret: ciphertext]
            )

          :skip ->
            :ok
        end
      end)
    end)
  end

  def down do
    with_vault(fn ->
      rows =
        repo().all(from(a in "apps", select: %{id: a.id, webhook_secret: a.webhook_secret}))

      Enum.each(rows, fn %{id: id, webhook_secret: secret} ->
        case decrypt_secret(secret) do
          {:ok, plaintext} ->
            repo().update_all(from(a in "apps", where: a.id == ^id),
              set: [webhook_secret: plaintext]
            )

          :skip ->
            :ok
        end
      end)
    end)
  end

  defp encrypt_secret(secret) when is_binary(secret) and secret != "" do
    case CleatDeploy.Vault.decrypt(secret) do
      {:ok, _plaintext} ->
        {:ok, secret}

      _error ->
        CleatDeploy.Vault.encrypt(secret)
    end
  end

  defp encrypt_secret(_secret), do: :skip

  defp decrypt_secret(secret) when is_binary(secret) and secret != "" do
    case CleatDeploy.Vault.decrypt(secret) do
      {:ok, plaintext} -> {:ok, plaintext}
      _error -> :skip
    end
  end

  defp decrypt_secret(_secret), do: :skip

  defp with_vault(fun) do
    case Process.whereis(CleatDeploy.Vault) do
      nil ->
        {:ok, pid} = CleatDeploy.Vault.start_link([])

        try do
          fun.()
        after
          GenServer.stop(pid)
        end

      _pid ->
        fun.()
    end
  end
end
