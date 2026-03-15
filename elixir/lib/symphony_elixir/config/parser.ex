defmodule SymphonyElixir.Config.Parser do
  @moduledoc false

  require Logger

  # Keys that can appear under either [agent] (preferred) or [codex] (deprecated).
  @agent_server_keys ~w(command turn_timeout_ms read_timeout_ms stall_timeout_ms)

  @doc false
  def extract_workflow_options(config) do
    %{
      tracker: extract_tracker_options(section_map(config, "tracker")),
      polling: extract_polling_options(section_map(config, "polling")),
      workspace: extract_workspace_options(section_map(config, "workspace")),
      agent: extract_agent_options(section_map(config, "agent")),
      agent_server: extract_agent_server_options(resolve_agent_server_section(config)),
      hooks: extract_hooks_options(section_map(config, "hooks")),
      observability: extract_observability_options(section_map(config, "observability")),
      server: extract_server_options(section_map(config, "server"))
    }
  end

  defp extract_tracker_options(section) do
    %{}
    |> put_if_present(:kind, normalize_tracker_kind(scalar_string_value(Map.get(section, "kind"))))
    |> put_if_present(:endpoint, scalar_string_value(Map.get(section, "endpoint")))
    |> put_if_present(:api_key, binary_value(Map.get(section, "api_key"), allow_empty: true))
    |> put_if_present(:project_slug, scalar_string_value(Map.get(section, "project_slug")))
    |> put_if_present(:active_states, csv_value(Map.get(section, "active_states")))
    |> put_if_present(:terminal_states, csv_value(Map.get(section, "terminal_states")))
  end

  defp extract_polling_options(section) do
    %{}
    |> put_if_present(:interval_ms, integer_value(Map.get(section, "interval_ms")))
  end

  defp extract_workspace_options(section) do
    %{}
    |> put_if_present(:root, binary_value(Map.get(section, "root")))
  end

  defp extract_agent_options(section) do
    %{}
    |> put_if_present(:max_concurrent_agents, integer_value(Map.get(section, "max_concurrent_agents")))
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(:max_retry_backoff_ms, positive_integer_value(Map.get(section, "max_retry_backoff_ms")))
    |> put_if_present(
      :max_concurrent_agents_by_state,
      state_limits_value(Map.get(section, "max_concurrent_agents_by_state"))
    )
    |> put_if_present(:fleet_pause_default_ms, positive_integer_value(Map.get(section, "fleet_pause_default_ms")))
    |> put_if_present(:fleet_pause_max_ms, positive_integer_value(Map.get(section, "fleet_pause_max_ms")))
    |> put_if_present(:fleet_pause_pattern_window_ms, positive_integer_value(Map.get(section, "fleet_pause_pattern_window_ms")))
    |> put_if_present(:fleet_pause_pattern_threshold, positive_integer_value(Map.get(section, "fleet_pause_pattern_threshold")))
    |> put_if_present(:fleet_probe_timeout_ms, positive_integer_value(Map.get(section, "fleet_probe_timeout_ms")))
    |> put_if_present(:shutdown_timeout_ms, positive_integer_value(Map.get(section, "shutdown_timeout_ms")))
  end

  defp extract_agent_server_options(section) do
    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
    |> put_if_present(:read_timeout_ms, integer_value(Map.get(section, "read_timeout_ms")))
    |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
  end

  defp extract_hooks_options(section) do
    %{}
    |> put_if_present(:after_create, hook_command_value(Map.get(section, "after_create")))
    |> put_if_present(:before_run, hook_command_value(Map.get(section, "before_run")))
    |> put_if_present(:after_run, hook_command_value(Map.get(section, "after_run")))
    |> put_if_present(:before_remove, hook_command_value(Map.get(section, "before_remove")))
    |> put_if_present(:timeout_ms, positive_integer_value(Map.get(section, "timeout_ms")))
    |> put_if_present(:allow_shell_hooks, boolean_value(Map.get(section, "allow_shell_hooks")))
  end

  defp extract_observability_options(section) do
    %{}
    |> put_if_present(:dashboard_enabled, boolean_value(Map.get(section, "dashboard_enabled")))
    |> put_if_present(:refresh_ms, integer_value(Map.get(section, "refresh_ms")))
    |> put_if_present(:render_interval_ms, integer_value(Map.get(section, "render_interval_ms")))
  end

  defp extract_server_options(section) do
    %{}
    |> put_if_present(:port, non_negative_integer_value(Map.get(section, "port")))
    |> put_if_present(:host, scalar_string_value(Map.get(section, "host")))
  end

  defp resolve_agent_server_section(config) do
    agent_server = section_map(config, "agent_server")
    agent = section_map(config, "agent")
    legacy = section_map(config, "codex")

    agent_server_subset = Map.take(agent_server, @agent_server_keys)
    agent_subset = Map.take(agent, @agent_server_keys)
    legacy_subset = Map.take(legacy, @agent_server_keys)

    fallback_keys = Map.keys(legacy_subset) -- (Map.keys(agent_subset) -- Map.keys(agent_server_subset))

    if fallback_keys != [] do
      Logger.warning("Config section [codex] is deprecated, use [agent] instead")
    end

    legacy_subset
    |> Map.merge(agent_subset)
    |> Map.merge(agent_server_subset)
  end

  defp section_map(config, key) do
    case Map.get(config, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp put_if_present(map, _key, :omit), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp scalar_string_value(nil), do: :omit
  defp scalar_string_value(value) when is_binary(value), do: String.trim(value)
  defp scalar_string_value(value) when is_boolean(value), do: to_string(value)
  defp scalar_string_value(value) when is_integer(value), do: to_string(value)
  defp scalar_string_value(value) when is_float(value), do: to_string(value)
  defp scalar_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar_string_value(_value), do: :omit

  defp binary_value(value, opts \\ [])

  defp binary_value(value, opts) when is_binary(value) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    if value == "" and not allow_empty do
      :omit
    else
      value
    end
  end

  defp binary_value(_value, _opts), do: :omit

  defp command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> trimmed
    end
  end

  defp command_value(_value), do: :omit

  defp hook_command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      _ -> String.trim_trailing(value)
    end
  end

  defp hook_command_value(_value), do: :omit

  defp csv_value(values) when is_list(values) do
    values
    |> Enum.reduce([], fn value, acc -> maybe_append_csv_value(acc, value) end)
    |> Enum.reverse()
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(_value), do: :omit

  defp maybe_append_csv_value(acc, value) do
    case scalar_string_value(value) do
      :omit ->
        acc

      normalized ->
        append_csv_value_if_present(acc, normalized)
    end
  end

  defp append_csv_value_if_present(acc, value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      acc
    else
      [trimmed | acc]
    end
  end

  defp integer_value(value) do
    case parse_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp positive_integer_value(value) do
    case parse_positive_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp non_negative_integer_value(value) do
    case parse_non_negative_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp boolean_value(value) when is_boolean(value), do: value

  defp boolean_value(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> :omit
    end
  end

  defp boolean_value(_value), do: :omit

  defp state_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {state_name, limit}, acc ->
      case parse_positive_integer(limit) do
        {:ok, parsed} ->
          Map.put(acc, normalize_issue_state(to_string(state_name)), parsed)

        :error ->
          acc
      end
    end)
  end

  defp state_limits_value(_value), do: :omit

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_positive_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_non_negative_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_kind(_kind), do: nil

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end
end
