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

  test "masks Signal/libsignal session key dumps" do
    message = """
    Closing session: SessionEntry {
      privKey: <Buffer 05 12 97 5f 65 ef 7e fb cd 70 8c 56 71 ca 36 3f ...>,
      rootKey: <Buffer 20 92 62 38 4f 12 1f 9e>,
      remoteIdentityKey: <Buffer 05 5a 5a d1 50 9f b0 82>,
      baseKey: <Buffer 90 fe 53 7b>
    }
    """

    redacted = Redact.message(message)

    refute redacted =~ "05 12 97 5f"
    refute redacted =~ "20 92 62 38"
    refute redacted =~ "05 5a 5a d1"
    refute redacted =~ "90 fe 53 7b"
    assert redacted =~ "[redacted]"
  end
end
