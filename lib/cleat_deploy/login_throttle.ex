defmodule CleatDeploy.LoginThrottle do
  @moduledoc """
  Fixed-window rate limiter for the token endpoint, keyed by client IP + email.

  Uses an ETS counter per `{key, window}` bucket, so there is no window-reset
  race and no shared process to supervise.
  """

  @table :cleat_login_throttle
  @window_ms 300_000
  @default_limit 10

  @doc "Returns `:ok` or `{:error, :rate_limited}`."
  def check(key) when is_binary(key) do
    ensure_table()
    bucket = div(System.monotonic_time(:millisecond), @window_ms)
    count = :ets.update_counter(@table, {key, bucket}, {2, 1}, {{key, bucket}, 0})

    if count > limit(), do: {:error, :rate_limited}, else: :ok
  end

  def limit, do: Application.get_env(:cleat_deploy, :login_throttle_limit, @default_limit)

  def window_ms, do: @window_ms

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          write_concurrency: true,
          read_concurrency: true
        ])

        :ok

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
