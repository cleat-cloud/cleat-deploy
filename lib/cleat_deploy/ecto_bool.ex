defmodule CleatDeploy.EctoBool do
  @moduledoc false
  # SQLite/LibSQL dumps of Turso rows store booleans as "true"/"false" text.
  # ecto_sqlite3 only special-cases "TRUE"/"FALSE", so Ecto.Type.Boolean.load
  # raises on the lowercase strings.
  use Ecto.Type

  def type, do: :boolean

  def cast(value) when is_boolean(value), do: {:ok, value}
  def cast(value), do: Ecto.Type.cast(:boolean, value)

  def load(value) when is_boolean(value), do: {:ok, value}
  def load(1), do: {:ok, true}
  def load(0), do: {:ok, false}
  def load("true"), do: {:ok, true}
  def load("TRUE"), do: {:ok, true}
  def load("false"), do: {:ok, false}
  def load("FALSE"), do: {:ok, false}
  def load(_), do: :error

  def dump(true), do: {:ok, true}
  def dump(false), do: {:ok, false}
  def dump(_), do: :error
end
