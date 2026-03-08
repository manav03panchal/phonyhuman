defmodule SymphonyElixir.RedactingFormatter do
  @moduledoc """
  A Logger formatter wrapper that applies secret redaction to all log output.

  Delegates formatting to a wrapped formatter module, then redacts any
  secrets from the resulting string before it is written to the log sink.

  Configure as:

      formatter: {SymphonyElixir.RedactingFormatter, %{wrapped_formatter: {:logger_formatter, %{single_line: true}}}}
  """

  alias SymphonyElixir.LogRedactor

  @spec format(:logger.log_event(), map()) :: String.t()
  def format(log_event, config) do
    {mod, mod_config} =
      Map.get(config, :wrapped_formatter, {:logger_formatter, %{single_line: true}})

    mod.format(log_event, mod_config)
    |> IO.chardata_to_string()
    |> LogRedactor.redact()
  end
end
