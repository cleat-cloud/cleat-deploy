defmodule CleatDeploy.Repo.Migrations.EncryptAppWebhookSecrets do
  use Ecto.Migration

  def up do
    with_vault(fn ->
      {:ok, %{rows: rows}} = repo().query("SELECT id, webhook_secret FROM apps", [])

      Enum.each(rows, fn [id, secret] ->
        case encrypt_secret(secret) do
          {:ok, ^secret} ->
            :ok

          {:ok, ciphertext} ->
            {:ok, _} =
              repo().query("UPDATE apps SET webhook_secret = ? WHERE id = ?", [ciphertext, id])

          :skip ->
            :ok
        end
      end)
    end)
  end

  def down do
    with_vault(fn ->
      {:ok, %{rows: rows}} = repo().query("SELECT id, webhook_secret FROM apps", [])

      Enum.each(rows, fn [id, secret] ->
        case decrypt_secret(secret) do
          {:ok, plaintext} ->
            {:ok, _} =
              repo().query("UPDATE apps SET webhook_secret = ? WHERE id = ?", [plaintext, id])

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
