defmodule SymphonyElixir.HookValidator do
  @moduledoc """
  Validates workspace hook commands against dangerous shell metacharacters.

  When `allow_shell_hooks` is `true` (default), commands containing dangerous
  patterns are allowed but a warning is emitted. When `false`, such commands
  are rejected.
  """

  @dangerous_patterns [
    {~r/;/, ";"},
    {~r/\|{2}/, "||"},
    {~r/(?<!\|)\|(?!\|)/, "|"},
    {~r/&&/, "&&"},
    {~r/\$\(/, "$("},
    {~r/`/, "`"},
    {~r/>{2}/, ">>"},
    {~r/(?<!>)>(?!>)/, ">"},
    {~r/<{2}/, "<<"},
    {~r/(?<!<)<(?!<)/, "<"},
    {~r/(?<![&|])&(?![&|])/, "&"}
  ]

  @type validation_result ::
          :ok
          | {:warn, [String.t()]}
          | {:error, {:dangerous_hook_command, String.t(), [String.t()]}}

  @spec validate(String.t(), boolean()) :: validation_result()
  def validate(command, allow_shell_hooks) when is_binary(command) and is_boolean(allow_shell_hooks) do
    found =
      @dangerous_patterns
      |> Enum.filter(fn {pattern, _label} -> Regex.match?(pattern, command) end)
      |> Enum.map(fn {_pattern, label} -> label end)

    case {found, allow_shell_hooks} do
      {[], _} -> :ok
      {patterns, true} -> {:warn, patterns}
      {patterns, false} -> {:error, {:dangerous_hook_command, command, patterns}}
    end
  end

  def validate(nil, _allow_shell_hooks), do: :ok

  @spec validate_all_hooks(map(), boolean()) :: :ok | {:error, term()}
  def validate_all_hooks(hooks, allow_shell_hooks) when is_map(hooks) and is_boolean(allow_shell_hooks) do
    hook_keys = [:after_create, :before_run, :after_run, :before_remove]

    Enum.reduce_while(hook_keys, :ok, fn key, :ok ->
      command = Map.get(hooks, key)

      case validate(command, allow_shell_hooks) do
        :ok ->
          {:cont, :ok}

        {:warn, _patterns} ->
          {:cont, :ok}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end
end
