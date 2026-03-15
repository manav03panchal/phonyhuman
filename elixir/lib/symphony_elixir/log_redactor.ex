defmodule SymphonyElixir.LogRedactor do
  @moduledoc """
  Redacts secrets and sensitive data from log output.

  Matches known secret formats (API keys, tokens, passwords) and replaces
  them with `[REDACTED]`. Only modifies strings for log display — never
  alters actual runtime data.
  """

  @redacted "[REDACTED]"

  # Combined pattern matching known secret formats:
  # - Linear API keys: lin_api_<chars>
  # - GitHub personal access tokens: ghp_<chars>
  # - GitHub user-to-server tokens: ghu_<chars>
  # - OpenAI/Anthropic-style keys: sk-<chars>
  # - Bearer tokens: Bearer <token>
  # - Query-string tokens: token=<value>
  # - Generic api_key parameters: api_key=<value>
  # - Environment-variable-style API keys: *API_KEY=<value>
  # - Password fields: password=<value> or password: <value>
  # - Authorization header tuples in inspected output: {"Authorization", "value"}
  @secret_pattern ~r/
    lin_api_\S+             |
    ghp_\S+                 |
    ghu_\S+                 |
    sk-\S+                  |
    Bearer\s+\S+            |
    token=\S+               |
    api_key=\S+             |
    [A-Z_]*API_KEY=\S+      |
    password=\S+            |
    password:\s*\S+         |
    "[Aa]uthorization",\s*"[^"]*"
  /x

  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    Regex.replace(@secret_pattern, text, @redacted)
  end

  def redact(text), do: text
end
