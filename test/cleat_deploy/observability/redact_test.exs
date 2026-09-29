defmodule CleatDeploy.Observability.RedactTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Observability.Redact

  test "masks secrets, tokens, connection strings and JWTs" do
    message =
      "password=supersecret token=abc123 DATABASE_URL=postgres://u:p@db/app Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.aaa.bbb AKIAIOSFODNN7EXAMPLE"

    redacted = Redact.message(message)

    refute redacted =~ "supersecret"
    refute redacted =~ "abc123"
    refute redacted =~ "postgres://u:p@"
    refute redacted =~ "eyJhbGciOiJIUzI1NiJ9"
    refute redacted =~ "AKIAIOSFODNN7EXAMPLE"
    assert redacted =~ "[redacted]"
  end

  test "leaves ordinary log lines alone" do
    assert Redact.message("request completed status=200") == "request completed status=200"
  end
end
