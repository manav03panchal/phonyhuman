defmodule SymphonyElixir.LogRedactorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LogRedactor

  describe "redact/1" do
    test "redacts Linear API keys (lin_api_ prefix)" do
      assert LogRedactor.redact("key is lin_api_abc123xyz") == "key is [REDACTED]"
    end

    test "redacts GitHub personal access tokens (ghp_ prefix)" do
      assert LogRedactor.redact("token: ghp_abcDEF123456") == "token: [REDACTED]"
    end

    test "redacts GitHub user-to-server tokens (ghu_ prefix)" do
      assert LogRedactor.redact("auth ghu_TokenValue789") == "auth [REDACTED]"
    end

    test "redacts OpenAI/Anthropic-style keys (sk- prefix)" do
      assert LogRedactor.redact("api key sk-proj-abcdef123") == "api key [REDACTED]"
    end

    test "redacts Bearer tokens" do
      assert LogRedactor.redact("Authorization: Bearer eyJhbGciOi") ==
               "Authorization: [REDACTED]"
    end

    test "redacts token= query parameters" do
      assert LogRedactor.redact("url?token=secret123&foo=bar") == "url?[REDACTED]"
    end

    test "redacts password= values" do
      assert LogRedactor.redact("password=hunter2") == "[REDACTED]"
    end

    test "redacts password: values" do
      assert LogRedactor.redact("password: hunter2") == "[REDACTED]"
    end

    test "redacts multiple secrets in one string" do
      input = "key=lin_api_abc token=ghp_xyz Bearer secret123"

      result = LogRedactor.redact(input)

      assert result =~ "[REDACTED]"
      refute result =~ "lin_api_abc"
      refute result =~ "ghp_xyz"
      refute result =~ "secret123"
    end

    test "passes non-sensitive content through unchanged" do
      input = "Agent session started for issue_id=abc issue_identifier=HUM-40 session_id=123"
      assert LogRedactor.redact(input) == input
    end

    test "handles empty string" do
      assert LogRedactor.redact("") == ""
    end

    test "handles non-binary input gracefully" do
      assert LogRedactor.redact(nil) == nil
      assert LogRedactor.redact(42) == 42
    end

    test "does not modify the original string reference" do
      original = "safe log message"
      redacted = LogRedactor.redact(original)
      assert original == "safe log message"
      assert redacted == "safe log message"
    end
  end
end
