defmodule SymphonyElixir.Orchestrator.TokenAccounting do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Orchestrator.State

  # --- Public functions called from Orchestrator ---

  @doc false
  def integrate_agent_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    agent_input_tokens = Map.get(running_entry, :agent_input_tokens, 0)
    agent_output_tokens = Map.get(running_entry, :agent_output_tokens, 0)
    agent_total_tokens = Map.get(running_entry, :agent_total_tokens, 0)
    agent_app_server_pid = Map.get(running_entry, :agent_app_server_pid)
    last_reported_input = Map.get(running_entry, :agent_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :agent_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :agent_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    agent_cache_read = Map.get(running_entry, :agent_cache_read_tokens, 0)
    agent_cache_creation = Map.get(running_entry, :agent_cache_creation_tokens, 0)
    agent_cost_usd = Map.get(running_entry, :agent_cost_usd, 0.0)

    delta_model = Map.get(token_delta, :model)

    {
      Map.merge(running_entry, %{
        last_agent_timestamp: timestamp,
        last_agent_message: summarize_agent_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_agent_event: event,
        agent_app_server_pid: agent_app_server_pid_for_update(agent_app_server_pid, update),
        agent_input_tokens: agent_input_tokens + token_delta.input_tokens,
        agent_output_tokens: agent_output_tokens + token_delta.output_tokens,
        agent_total_tokens: agent_total_tokens + token_delta.total_tokens,
        agent_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        agent_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        agent_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        agent_cache_read_tokens: agent_cache_read + Map.get(token_delta, :cache_read_tokens, 0),
        agent_cache_creation_tokens: agent_cache_creation + Map.get(token_delta, :cache_creation_tokens, 0),
        agent_cost_usd: agent_cost_usd + Map.get(token_delta, :cost_usd, 0.0),
        agent_model: if(delta_model, do: delta_model, else: Map.get(running_entry, :agent_model))
      }),
      token_delta
    }
  end

  @doc false
  def record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    agent_totals =
      apply_token_delta(
        state.agent_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds,
          cache_read_tokens: 0,
          cache_creation_tokens: 0,
          cost_usd: 0.0,
          model: nil,
          tool_calls: Map.get(running_entry, :otel_tool_calls, 0),
          tool_duration_total_ms: Map.get(running_entry, :otel_tool_duration_total_ms, 0),
          tool_errors: Map.get(running_entry, :otel_tool_errors, 0),
          api_errors: Map.get(running_entry, :otel_api_errors, 0),
          lines_changed: Map.get(running_entry, :otel_lines_changed, 0),
          commits_count: Map.get(running_entry, :otel_commits_count, 0),
          prs_count: Map.get(running_entry, :otel_prs_count, 0),
          active_time_seconds: Map.get(running_entry, :otel_active_time_seconds, 0)
        }
      )

    %{state | agent_totals: agent_totals}
  end

  def record_session_completion_totals(state, _running_entry), do: state

  @doc false
  def apply_token_delta(agent_totals, token_delta) do
    input_tokens = Map.get(agent_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(agent_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(agent_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(agent_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    cache_read_tokens =
      Map.get(agent_totals, :cache_read_tokens, 0) + Map.get(token_delta, :cache_read_tokens, 0)

    cache_creation_tokens =
      Map.get(agent_totals, :cache_creation_tokens, 0) +
        Map.get(token_delta, :cache_creation_tokens, 0)

    cost_usd =
      Map.get(agent_totals, :cost_usd, 0.0) + Map.get(token_delta, :cost_usd, 0.0)

    delta_model = Map.get(token_delta, :model)
    model = if delta_model, do: delta_model, else: Map.get(agent_totals, :model)

    tool_calls =
      Map.get(agent_totals, :tool_calls, 0) + Map.get(token_delta, :tool_calls, 0)

    tool_duration_total_ms =
      Map.get(agent_totals, :tool_duration_total_ms, 0) +
        Map.get(token_delta, :tool_duration_total_ms, 0)

    tool_errors =
      Map.get(agent_totals, :tool_errors, 0) + Map.get(token_delta, :tool_errors, 0)

    api_errors =
      Map.get(agent_totals, :api_errors, 0) + Map.get(token_delta, :api_errors, 0)

    lines_changed =
      max(Map.get(agent_totals, :lines_changed, 0), Map.get(token_delta, :lines_changed, 0))

    commits_count =
      max(Map.get(agent_totals, :commits_count, 0), Map.get(token_delta, :commits_count, 0))

    prs_count =
      max(Map.get(agent_totals, :prs_count, 0), Map.get(token_delta, :prs_count, 0))

    active_time_seconds =
      max(
        Map.get(agent_totals, :active_time_seconds, 0),
        Map.get(token_delta, :active_time_seconds, 0)
      )

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running),
      cache_read_tokens: max(0, cache_read_tokens),
      cache_creation_tokens: max(0, cache_creation_tokens),
      cost_usd: max(0.0, cost_usd),
      model: model,
      tool_calls: max(0, tool_calls),
      tool_duration_total_ms: max(0, tool_duration_total_ms),
      tool_errors: max(0, tool_errors),
      api_errors: max(0, api_errors),
      lines_changed: max(0, lines_changed),
      commits_count: max(0, commits_count),
      prs_count: max(0, prs_count),
      active_time_seconds: max(0, active_time_seconds)
    }
  end

  @doc false
  def apply_agent_token_delta(
        %{agent_totals: agent_totals} = state,
        %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
      )
      when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | agent_totals: apply_token_delta(agent_totals, token_delta)}
  end

  def apply_agent_token_delta(state, _token_delta), do: state

  @doc false
  def apply_agent_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | agent_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  def apply_agent_rate_limits(state, _update), do: state

  @doc false
  def extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :agent_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :agent_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :agent_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported,
        cache_read_tokens: extract_cache_read_tokens(usage),
        cache_creation_tokens: extract_cache_creation_tokens(usage),
        cost_usd: extract_cost_usd(update),
        model: extract_model(update)
      }
    end)
  end

  @doc false
  def extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  @doc false
  def merge_otel_metrics(running_entry, metrics) when is_map(running_entry) and is_map(metrics) do
    running_entry
    |> merge_otel_token_data(metrics)
    |> merge_otel_tool_executions(metrics)
    |> merge_otel_api_errors(metrics)
    |> merge_otel_lines_changed(metrics)
    |> merge_otel_commits_count(metrics)
    |> merge_otel_prs_count(metrics)
    |> merge_otel_active_time(metrics)
  end

  @doc false
  def running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  def running_seconds(_started_at, _now), do: 0

  @doc false
  def find_issue_id_for_session(running, session_id) when is_map(running) and is_binary(session_id) do
    Enum.find_value(running, fn
      {issue_id, %{session_id: ^session_id}} -> issue_id
      _ -> nil
    end)
  end

  # --- Private functions ---

  defp agent_app_server_pid_for_update(_existing, %{agent_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp agent_app_server_pid_for_update(_existing, %{agent_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp agent_app_server_pid_for_update(_existing, %{agent_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp agent_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_agent_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        if is_integer(next_total) and next_total < prev_reported do
          Logger.debug("Token delta clamped to 0: dimension=#{token_key} prev_reported=#{prev_reported} next_reported=#{next_total}")
        end

        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_cache_read_tokens(usage) when is_map(usage) do
    value =
      Map.get(usage, "cache_read_input_tokens") ||
        Map.get(usage, :cache_read_input_tokens) ||
        Map.get(usage, "cache_read_tokens") ||
        Map.get(usage, :cache_read_tokens)

    if is_integer(value) and value >= 0, do: value, else: 0
  end

  defp extract_cache_read_tokens(_usage), do: 0

  defp extract_cache_creation_tokens(usage) when is_map(usage) do
    value =
      Map.get(usage, "cache_creation_input_tokens") ||
        Map.get(usage, :cache_creation_input_tokens) ||
        Map.get(usage, "cache_creation_tokens") ||
        Map.get(usage, :cache_creation_tokens)

    if is_integer(value) and value >= 0, do: value, else: 0
  end

  defp extract_cache_creation_tokens(_usage), do: 0

  defp extract_cost_usd(update) when is_map(update) do
    value =
      Map.get(update, :cost_usd) ||
        Map.get(update, "cost_usd") ||
        get_in_fleet(update, [:usage, :cost_usd]) ||
        get_in_fleet(update, [:usage, "cost_usd"]) ||
        get_in_fleet(update, ["usage", "cost_usd"]) ||
        get_in_fleet(update, [:payload, :cost_usd]) ||
        get_in_fleet(update, [:payload, "cost_usd"]) ||
        get_in_fleet(update, ["payload", "cost_usd"]) ||
        get_in_fleet(update, [:payload, :params, :cost_usd]) ||
        get_in_fleet(update, [:payload, "params", "cost_usd"]) ||
        get_in_fleet(update, ["payload", "params", "cost_usd"])

    cond do
      is_float(value) and value >= 0.0 -> value
      is_integer(value) and value >= 0 -> value / 1
      true -> 0.0
    end
  end

  defp extract_cost_usd(_update), do: 0.0

  defp extract_model(update) when is_map(update) do
    Map.get(update, :model) ||
      Map.get(update, "model") ||
      get_in_fleet(update, [:usage, :model]) ||
      get_in_fleet(update, [:usage, "model"]) ||
      get_in_fleet(update, ["usage", "model"]) ||
      get_in_fleet(update, [:payload, :model]) ||
      get_in_fleet(update, [:payload, "model"]) ||
      get_in_fleet(update, ["payload", "model"]) ||
      get_in_fleet(update, [:payload, :params, :model]) ||
      get_in_fleet(update, [:payload, "params", "model"]) ||
      get_in_fleet(update, ["payload", "params", "model"])
  end

  defp extract_model(_update), do: nil

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      Enum.find_value(payloads, &flat_token_usage_from_payload/1) ||
      %{}
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp flat_token_usage_from_payload(payload) when is_map(payload) do
    if integer_token_map?(payload), do: payload
  end

  defp flat_token_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp get_in_fleet(update, keys) when is_map(update) and is_list(keys) do
    Enum.reduce_while(keys, update, fn key, acc ->
      if is_map(acc), do: {:cont, Map.get(acc, key)}, else: {:halt, nil}
    end)
  end

  # --- OTel metric integration ---

  defp merge_otel_token_data(entry, metrics) do
    token_data = Map.get(metrics, "claude_code.token.usage", [])
    cost_data = Map.get(metrics, "claude_code.cost.usage", [])

    input = otel_token_value(token_data, "input")
    output = otel_token_value(token_data, "output")
    cache_read = otel_token_value(token_data, "cache_read")
    cache_creation = otel_token_value(token_data, "cache_creation")
    cost = otel_cost_value(cost_data)

    entry
    |> maybe_update_otel(:otel_input_tokens, input)
    |> maybe_update_otel(:otel_output_tokens, output)
    |> maybe_update_otel(:otel_cache_read_tokens, cache_read)
    |> maybe_update_otel(:otel_cache_creation_tokens, cache_creation)
    |> maybe_update_otel_float(:otel_cost_usd, cost)
  end

  defp otel_token_value(data_points, type) when is_list(data_points) do
    Enum.find_value(data_points, fn
      %{value: value, attributes: %{"type" => ^type}} when is_integer(value) -> value
      _ -> nil
    end)
  end

  defp otel_cost_value(data_points) when is_list(data_points) do
    Enum.find_value(data_points, fn
      %{value: value} when is_number(value) -> value
      _ -> nil
    end)
  end

  defp otel_cost_value(_), do: nil

  defp maybe_update_otel(entry, _key, nil), do: entry

  defp maybe_update_otel(entry, key, value) when is_integer(value) and value >= 0 do
    Map.put(entry, key, value)
  end

  defp maybe_update_otel(entry, _key, _value), do: entry

  defp maybe_update_otel_float(entry, _key, nil), do: entry

  defp maybe_update_otel_float(entry, key, value) when is_number(value) and value >= 0 do
    Map.put(entry, key, value / 1)
  end

  defp maybe_update_otel_float(entry, _key, _value), do: entry

  defp merge_otel_tool_executions(entry, metrics) do
    events = Map.get(metrics, :events, [])

    {count, duration_ms, errors} =
      Enum.reduce(events, {0, 0, 0}, fn
        %{name: "claude_code.tool_result", attributes: attrs}, {c, d, e} when is_map(attrs) ->
          dur = otel_numeric(Map.get(attrs, "duration_ms", 0))
          err = if Map.get(attrs, "success", true), do: 0, else: 1
          {c + 1, d + dur, e + err}

        _, acc ->
          acc
      end)

    if count > 0 do
      entry
      |> Map.update(:otel_tool_calls, count, &(&1 + count))
      |> Map.update(:otel_tool_duration_total_ms, duration_ms, &(&1 + duration_ms))
      |> Map.update(:otel_tool_errors, errors, &(&1 + errors))
    else
      entry
    end
  end

  defp merge_otel_api_errors(entry, metrics) do
    metric_count = otel_sum_value(Map.get(metrics, "claude_code.api_error", []))

    event_count =
      metrics
      |> Map.get(:events, [])
      |> Enum.count(fn
        %{name: "claude_code.api_error"} -> true
        _ -> false
      end)

    total = metric_count + event_count

    if total > 0 do
      Map.put(entry, :otel_api_errors, Map.get(entry, :otel_api_errors, 0) + total)
    else
      entry
    end
  end

  defp merge_otel_lines_changed(entry, metrics) do
    value = otel_sum_value(Map.get(metrics, "claude_code.lines_of_code.count", []))

    if value > 0 do
      Map.put(entry, :otel_lines_changed, value)
    else
      entry
    end
  end

  defp merge_otel_commits_count(entry, metrics) do
    value = otel_sum_value(Map.get(metrics, "claude_code.commit.count", []))

    if value > 0 do
      Map.put(entry, :otel_commits_count, value)
    else
      entry
    end
  end

  defp merge_otel_prs_count(entry, metrics) do
    value = otel_sum_value(Map.get(metrics, "claude_code.pull_request.count", []))

    if value > 0 do
      Map.put(entry, :otel_prs_count, value)
    else
      entry
    end
  end

  defp merge_otel_active_time(entry, metrics) do
    value = otel_sum_value(Map.get(metrics, "claude_code.active_time.total", []))

    if value > 0 do
      Map.put(entry, :otel_active_time_seconds, value)
    else
      entry
    end
  end

  defp otel_sum_value(data_points) when is_list(data_points) do
    Enum.reduce(data_points, 0, fn
      %{value: value}, acc when is_number(value) -> acc + value
      _, acc -> acc
    end)
  end

  defp otel_sum_value(_), do: 0

  defp otel_numeric(value) when is_integer(value), do: value
  defp otel_numeric(value) when is_float(value), do: round(value)

  defp otel_numeric(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp otel_numeric(_), do: 0
end
