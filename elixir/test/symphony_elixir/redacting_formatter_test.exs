defmodule SymphonyElixir.RedactingFormatterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RedactingFormatter

  describe "format/2" do
    test "redacts secrets in formatted log output" do
      log_event = %{
        level: :warning,
        msg: {:string, "Agent output: lin_api_secret123"},
        meta: %{time: :os.system_time(:microsecond)}
      }

      config = %{
        wrapped_formatter: {:logger_formatter, %{single_line: true, template: [:msg]}}
      }

      result = RedactingFormatter.format(log_event, config)
      assert result =~ "[REDACTED]"
      refute result =~ "lin_api_secret123"
    end

    test "passes non-sensitive log output through unchanged" do
      log_event = %{
        level: :info,
        msg: {:string, "Agent session started"},
        meta: %{time: :os.system_time(:microsecond)}
      }

      config = %{
        wrapped_formatter: {:logger_formatter, %{single_line: true, template: [:msg]}}
      }

      result = RedactingFormatter.format(log_event, config)
      assert result =~ "Agent session started"
    end

    test "uses default formatter when no wrapped_formatter specified" do
      log_event = %{
        level: :info,
        msg: {:string, "ghp_secret_token here"},
        meta: %{time: :os.system_time(:microsecond)}
      }

      result = RedactingFormatter.format(log_event, %{})
      assert result =~ "[REDACTED]"
      refute result =~ "ghp_secret_token"
    end
  end
end
