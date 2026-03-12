defmodule SymphonyElixir.RuntimeConfig do
  @moduledoc false

  require Logger

  @default_port 4000

  @spec parse_port() :: pos_integer()
  def parse_port do
    case System.get_env("PORT") do
      nil ->
        @default_port

      val ->
        case Integer.parse(val) do
          {port, ""} when port >= 1 and port <= 65_535 ->
            port

          {_port, ""} ->
            Logger.warning("PORT=#{val} is outside valid range 1-65535, falling back to #{@default_port}")
            @default_port

          _ ->
            Logger.warning("PORT=#{val} is not a valid integer, falling back to #{@default_port}")
            @default_port
        end
    end
  end

  @spec secret_key_base!(atom()) :: String.t()
  def secret_key_base!(env) do
    case {env, System.get_env("SECRET_KEY_BASE")} do
      {:prod, nil} ->
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

      {_env, nil} ->
        :crypto.strong_rand_bytes(64) |> Base.encode64() |> binary_part(0, 64)

      {_env, value} ->
        value
    end
  end

  @spec check_origin() :: boolean() | [String.t()]
  def check_origin do
    case System.get_env("ALLOWED_ORIGINS") do
      nil ->
        true

      origins ->
        origins |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end
end
