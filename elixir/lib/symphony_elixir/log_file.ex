defmodule SymphonyElixir.LogFile do
  @moduledoc """
  Configures OTP's built-in standard file handler for application logs.

  Uses `logger_std_h` (standard file handler) instead of `logger_disk_log_h`
  to avoid disk_log subsystem failures in escript/backgrounded contexts.
  File rotation is handled via `max_no_bytes` and `max_no_files`.
  """

  require Logger

  @handler_id :symphony_file_log
  @default_log_relative_path "log/symphony.log"
  @default_max_bytes 10 * 1024 * 1024
  @default_max_files 5

  @spec default_log_file() :: Path.t()
  def default_log_file do
    default_log_file(File.cwd!())
  end

  @spec default_log_file(Path.t()) :: Path.t()
  def default_log_file(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_log_relative_path)
  end

  @spec configure() :: :ok
  def configure do
    log_file = Application.get_env(:symphony_elixir, :log_file, default_log_file())
    max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes, @default_max_bytes)
    max_files = Application.get_env(:symphony_elixir, :log_file_max_files, @default_max_files)

    setup_file_handler(log_file, max_bytes, max_files)
  end

  defp setup_file_handler(log_file, max_bytes, max_files) do
    expanded_path = Path.expand(log_file)
    :ok = File.mkdir_p(Path.dirname(expanded_path))
    :ok = remove_existing_handler()

    case :logger.add_handler(
           @handler_id,
           :logger_std_h,
           file_handler_config(expanded_path, max_bytes, max_files)
         ) do
      :ok ->
        remove_default_console_handler()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to configure file log handler: #{inspect(reason)}")
        :ok
    end
  end

  defp remove_existing_handler do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, {:not_found, @handler_id}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp remove_default_console_handler do
    case :logger.remove_handler(:default) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp file_handler_config(path, max_bytes, max_files) do
    %{
      level: :all,
      formatter: {SymphonyElixir.RedactingFormatter, %{wrapped_formatter: {:logger_formatter, %{single_line: true}}}},
      config: %{
        file: String.to_charlist(path),
        max_no_bytes: max_bytes,
        max_no_files: max_files
      }
    }
  end
end
