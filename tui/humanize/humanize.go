// Package humanize converts raw agent event payloads into human-readable
// status strings. It is a Go port of the Elixir humanize_agent_message/1
// logic from symphony_elixir/status_dashboard.ex.
package humanize

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

const maxLen = 140

// AgentMessage converts a raw agent event map into a short human-readable
// string. The input is typically a JSON-decoded map[string]interface{} from the
// Symphony API. Returns "no agent message yet" for nil input.
func AgentMessage(msg map[string]interface{}) string {
	if msg == nil {
		return "no agent message yet"
	}

	event, _ := msg["event"].(string)
	message := asMap(msg["message"])

	payload := unwrapPayload(message)
	if payload == nil {
		payload = unwrapPayload(msg)
	}

	if event != "" && payload != nil {
		if text := humanizeEvent(event, msg, payload); text != "" {
			return truncate(text, maxLen)
		}
	}

	if payload != nil {
		return truncate(humanizePayload(payload), maxLen)
	}

	return truncate("no agent message yet", maxLen)
}

// --- event dispatch ---

func humanizeEvent(event string, message, payload map[string]interface{}) string {
	switch event {
	case "session_started":
		if sid, ok := getString(payload, "session_id"); ok {
			return fmt.Sprintf("session started (%s)", sid)
		}
		return "session started"

	case "turn_input_required":
		return "turn blocked: waiting for user input"

	case "approval_auto_approved":
		method := firstString(payload, "method")
		if method == "" {
			method = mapPathStr(message, "payload", "method")
		}
		decision, _ := getString(message, "decision")
		base := "approval request auto-approved"
		if method != "" {
			base = humanizeMethod(method, payload) + " (auto-approved)"
		}
		if decision != "" {
			return base + ": " + decision
		}
		return base

	case "tool_input_auto_answered":
		answer, _ := getString(message, "answer")
		base := "tool input auto-answered"
		if text := humanizeMethod("item/tool/requestUserInput", payload); text != "" {
			base = text + " (auto-answered)"
		}
		if answer != "" {
			return base + ": " + inlineText(answer)
		}
		return base

	case "tool_call_completed":
		return dynamicToolEvent("dynamic tool call completed", payload)
	case "tool_call_failed":
		return dynamicToolEvent("dynamic tool call failed", payload)
	case "unsupported_tool_call":
		return dynamicToolEvent("unsupported dynamic tool call rejected", payload)

	case "turn_ended_with_error":
		return "turn ended with error: " + formatReason(message)
	case "startup_failed":
		return "startup failed: " + formatReason(message)
	case "turn_failed":
		return humanizeMethod("turn/failed", payload)
	case "turn_cancelled":
		return "turn cancelled"
	case "malformed":
		return "malformed JSON event from agent"
	}

	return ""
}

// --- payload dispatch ---

func humanizePayload(payload map[string]interface{}) string {
	if method := firstString(payload, "method"); method != "" {
		return humanizeMethod(method, payload)
	}
	if sid, ok := getString(payload, "session_id"); ok {
		return fmt.Sprintf("session started (%s)", sid)
	}
	if errVal, ok := payload["error"]; ok {
		return "error: " + formatErrorValue(errVal)
	}
	return compactMap(payload)
}

// --- method dispatch ---

func humanizeMethod(method string, payload map[string]interface{}) string {
	switch method {
	case "thread/started":
		if id := mapPathStr(payload, "params", "thread", "id"); id != "" {
			return fmt.Sprintf("thread started (%s)", id)
		}
		return "thread started"

	case "turn/started":
		if id := mapPathStr(payload, "params", "turn", "id"); id != "" {
			return fmt.Sprintf("turn started (%s)", id)
		}
		return "turn started"

	case "turn/completed":
		status := mapPathStr(payload, "params", "turn", "status")
		if status == "" {
			status = "completed"
		}
		usage := mapPathMap(payload, "params", "usage")
		if usage == nil {
			usage = mapPathMap(payload, "params", "tokenUsage")
		}
		if usage == nil {
			if u := asMap(payload["usage"]); u != nil {
				usage = u
			}
		}
		suffix := ""
		if text := formatUsageCounts(usage); text != "" {
			suffix = " (" + text + ")"
		}
		return fmt.Sprintf("turn completed (%s)%s", status, suffix)

	case "turn/failed":
		if msg := mapPathStr(payload, "params", "error", "message"); msg != "" {
			return "turn failed: " + msg
		}
		return "turn failed"

	case "turn/cancelled":
		return "turn cancelled"

	case "turn/diff/updated":
		diff := mapPathStr(payload, "params", "diff")
		if diff != "" {
			lines := len(strings.Split(strings.TrimSpace(diff), "\n"))
			return fmt.Sprintf("turn diff updated (%d lines)", lines)
		}
		return "turn diff updated"

	case "turn/plan/updated":
		plan := mapPathSlice(payload, "params", "plan")
		if plan == nil {
			plan = mapPathSlice(payload, "params", "steps")
		}
		if plan == nil {
			plan = mapPathSlice(payload, "params", "items")
		}
		if plan != nil {
			return fmt.Sprintf("plan updated (%d steps)", len(plan))
		}
		return "plan updated"

	case "thread/tokenUsage/updated":
		usage := mapPathMap(payload, "params", "tokenUsage", "total")
		if usage == nil {
			if u := asMap(payload["usage"]); u != nil {
				usage = u
			}
		}
		if text := formatUsageCounts(usage); text != "" {
			return "thread token usage updated (" + text + ")"
		}
		return "thread token usage updated"

	case "item/started":
		return humanizeItemLifecycle("started", payload)
	case "item/completed":
		return humanizeItemLifecycle("completed", payload)

	case "item/agentMessage/delta":
		return streamingEvent("agent message streaming", payload)
	case "item/plan/delta":
		return streamingEvent("plan streaming", payload)
	case "item/reasoning/summaryTextDelta":
		return streamingEvent("reasoning summary streaming", payload)
	case "item/reasoning/summaryPartAdded":
		return streamingEvent("reasoning summary section added", payload)
	case "item/reasoning/textDelta":
		return streamingEvent("reasoning text streaming", payload)
	case "item/commandExecution/outputDelta":
		return streamingEvent("command output streaming", payload)
	case "item/fileChange/outputDelta":
		return streamingEvent("file change output streaming", payload)

	case "item/commandExecution/requestApproval":
		if cmd := extractCommand(payload); cmd != "" {
			return fmt.Sprintf("command approval requested (%s)", cmd)
		}
		return "command approval requested"

	case "item/fileChange/requestApproval":
		if count := mapPathInt(payload, "params", "fileChangeCount"); count > 0 {
			return fmt.Sprintf("file change approval requested (%d files)", count)
		}
		if count := mapPathInt(payload, "params", "changeCount"); count > 0 {
			return fmt.Sprintf("file change approval requested (%d files)", count)
		}
		return "file change approval requested"

	case "item/tool/requestUserInput", "tool/requestUserInput":
		q := mapPathStr(payload, "params", "question")
		if q == "" {
			q = mapPathStr(payload, "params", "prompt")
		}
		if strings.TrimSpace(q) != "" {
			return "tool requires user input: " + inlineText(q)
		}
		return "tool requires user input"

	case "account/updated":
		authMode := mapPathStr(payload, "params", "authMode")
		if authMode == "" {
			authMode = "unknown"
		}
		return fmt.Sprintf("account updated (auth %s)", authMode)

	case "account/rateLimits/updated":
		rl := mapPathMap(payload, "params", "rateLimits")
		return "rate limits updated: " + formatRateLimitsSummary(rl)

	case "account/chatgptAuthTokens/refresh":
		return "account auth token refresh requested"

	case "item/tool/call":
		if tool := dynamicToolName(payload); tool != "" {
			return fmt.Sprintf("dynamic tool call requested (%s)", tool)
		}
		return "dynamic tool call requested"
	}

	// codex/event/* wrapper events
	if strings.HasPrefix(method, "codex/event/") {
		suffix := strings.TrimPrefix(method, "codex/event/")
		return humanizeWrapperEvent(suffix, payload)
	}

	// fallback: method name with optional msg type
	if msgType := mapPathStr(payload, "params", "msg", "type"); msgType != "" {
		return fmt.Sprintf("%s (%s)", method, msgType)
	}
	return method
}

// --- wrapper events ---

func humanizeWrapperEvent(suffix string, payload map[string]interface{}) string {
	switch suffix {
	case "mcp_startup_update":
		server := mapPathStr(payload, "params", "msg", "server")
		if server == "" {
			server = "mcp"
		}
		state := mapPathStr(payload, "params", "msg", "status", "state")
		if state == "" {
			state = "updated"
		}
		return fmt.Sprintf("mcp startup: %s %s", server, state)

	case "mcp_startup_complete":
		return "mcp startup complete"
	case "task_started":
		return "task started"
	case "user_message":
		return "user message received"

	case "item_started":
		if t := wrapperPayloadType(payload); t == "token_count" {
			return humanizeWrapperEvent("token_count", payload)
		} else if t != "" {
			return fmt.Sprintf("item started (%s)", humanizeItemType(t))
		}
		return "item started"

	case "item_completed":
		if t := wrapperPayloadType(payload); t == "token_count" {
			return humanizeWrapperEvent("token_count", payload)
		} else if t != "" {
			return fmt.Sprintf("item completed (%s)", humanizeItemType(t))
		}
		return "item completed"

	case "agent_message_delta":
		return streamingEvent("agent message streaming", payload)
	case "agent_message_content_delta":
		return streamingEvent("agent message content streaming", payload)
	case "agent_reasoning_delta":
		return streamingEvent("reasoning streaming", payload)
	case "reasoning_content_delta":
		return streamingEvent("reasoning content streaming", payload)
	case "agent_reasoning_section_break":
		return "reasoning section break"
	case "agent_reasoning":
		return humanizeReasoningUpdate(payload)
	case "turn_diff":
		return "turn diff updated"
	case "exec_command_begin":
		return humanizeExecCommandBegin(payload)
	case "exec_command_end":
		return humanizeExecCommandEnd(payload)
	case "exec_command_output_delta":
		return "command output streaming"
	case "mcp_tool_call_begin":
		return "mcp tool call started"
	case "mcp_tool_call_end":
		return "mcp tool call completed"

	case "token_count":
		usage := extractTokenUsage(payload)
		if text := formatUsageCounts(usage); text != "" {
			return "token count update (" + text + ")"
		}
		return "token count update"
	}

	// fallback
	if msgType := mapPathStr(payload, "params", "msg", "type"); msgType != "" {
		return fmt.Sprintf("%s (%s)", suffix, msgType)
	}
	return suffix
}

// --- helpers ---

func humanizeItemLifecycle(state string, payload map[string]interface{}) string {
	item := mapPathMap(payload, "params", "item")
	if item == nil {
		item = map[string]interface{}{}
	}
	itemType := humanizeItemType(firstString(item, "type"))
	itemStatus := firstString(item, "status")
	itemID := firstString(item, "id")

	var details []string
	if id := shortID(itemID); id != "" {
		details = append(details, id)
	}
	if s := humanizeStatus(itemStatus); s != "" {
		details = append(details, s)
	}

	suffix := ""
	if len(details) > 0 {
		suffix = " (" + strings.Join(details, ", ") + ")"
	}
	return fmt.Sprintf("item %s: %s%s", state, itemType, suffix)
}

func streamingEvent(label string, payload map[string]interface{}) string {
	if preview := extractDeltaPreview(payload); preview != "" {
		return label + ": " + preview
	}
	return label
}

func humanizeReasoningUpdate(payload map[string]interface{}) string {
	if focus := extractReasoningFocus(payload); focus != "" {
		return "reasoning update: " + focus
	}
	return "reasoning update"
}

func humanizeExecCommandBegin(payload map[string]interface{}) string {
	cmd := mapPathStr(payload, "params", "msg", "command")
	if cmd == "" {
		cmd = mapPathStr(payload, "params", "msg", "parsed_cmd")
	}
	if cmd != "" {
		return inlineText(cmd)
	}
	return "command started"
}

func humanizeExecCommandEnd(payload map[string]interface{}) string {
	exitCode := mapPathInt(payload, "params", "msg", "exit_code")
	if exitCode != 0 {
		return fmt.Sprintf("command completed (exit %d)", exitCode)
	}
	// check if exit_code key exists with value 0
	if v := mapPath(payload, "params", "msg", "exit_code"); v != nil {
		return "command completed (exit 0)"
	}
	exitCode = mapPathInt(payload, "params", "msg", "exitCode")
	if exitCode != 0 {
		return fmt.Sprintf("command completed (exit %d)", exitCode)
	}
	if v := mapPath(payload, "params", "msg", "exitCode"); v != nil {
		return "command completed (exit 0)"
	}
	return "command completed"
}

func dynamicToolEvent(base string, payload map[string]interface{}) string {
	if tool := dynamicToolName(payload); strings.TrimSpace(tool) != "" {
		return fmt.Sprintf("%s (%s)", base, strings.TrimSpace(tool))
	}
	return base
}

func dynamicToolName(payload map[string]interface{}) string {
	if t := mapPathStr(payload, "params", "tool"); t != "" {
		return t
	}
	return mapPathStr(payload, "params", "name")
}

func extractCommand(payload map[string]interface{}) string {
	cmd := mapPathStr(payload, "params", "parsedCmd")
	if cmd == "" {
		cmd = mapPathStr(payload, "params", "command")
	}
	if cmd == "" {
		cmd = mapPathStr(payload, "params", "cmd")
	}
	if cmd != "" {
		return inlineText(cmd)
	}
	return ""
}

func extractDeltaPreview(payload map[string]interface{}) string {
	paths := [][]string{
		{"params", "delta"},
		{"params", "msg", "delta"},
		{"params", "textDelta"},
		{"params", "msg", "textDelta"},
		{"params", "outputDelta"},
		{"params", "msg", "outputDelta"},
		{"params", "text"},
		{"params", "msg", "text"},
		{"params", "summaryText"},
		{"params", "msg", "summaryText"},
		{"params", "msg", "content"},
		{"params", "msg", "payload", "delta"},
		{"params", "msg", "payload", "textDelta"},
		{"params", "msg", "payload", "outputDelta"},
		{"params", "msg", "payload", "text"},
		{"params", "msg", "payload", "summaryText"},
		{"params", "msg", "payload", "content"},
	}
	for _, path := range paths {
		if v := mapPath(payload, path...); v != nil {
			if s, ok := v.(string); ok && strings.TrimSpace(s) != "" {
				return inlineText(strings.TrimSpace(s))
			}
		}
	}
	return ""
}

func extractReasoningFocus(payload map[string]interface{}) string {
	paths := [][]string{
		{"params", "reason"},
		{"params", "summaryText"},
		{"params", "summary"},
		{"params", "text"},
		{"params", "msg", "reason"},
		{"params", "msg", "summaryText"},
		{"params", "msg", "summary"},
		{"params", "msg", "text"},
		{"params", "msg", "payload", "reason"},
		{"params", "msg", "payload", "summaryText"},
		{"params", "msg", "payload", "summary"},
		{"params", "msg", "payload", "text"},
	}
	for _, path := range paths {
		if v := mapPath(payload, path...); v != nil {
			if s, ok := v.(string); ok && strings.TrimSpace(s) != "" {
				return inlineText(strings.TrimSpace(s))
			}
		}
	}
	return ""
}

func extractTokenUsage(payload map[string]interface{}) map[string]interface{} {
	paths := [][]string{
		{"params", "msg", "payload", "info", "total_token_usage"},
		{"params", "msg", "info", "total_token_usage"},
		{"params", "tokenUsage", "total"},
	}
	for _, path := range paths {
		if v := mapPath(payload, path...); v != nil {
			if m, ok := v.(map[string]interface{}); ok {
				return m
			}
		}
	}
	return nil
}

func wrapperPayloadType(payload map[string]interface{}) string {
	return mapPathStr(payload, "params", "msg", "payload", "type")
}

func formatUsageCounts(usage map[string]interface{}) string {
	if usage == nil {
		return ""
	}
	input := parseIntFromKeys(usage, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens")
	output := parseIntFromKeys(usage, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")
	total := parseIntFromKeys(usage, "total_tokens", "total", "totalTokens")

	var parts []string
	if input > 0 {
		parts = append(parts, fmt.Sprintf("in %s", formatCount(input)))
	}
	if output > 0 {
		parts = append(parts, fmt.Sprintf("out %s", formatCount(output)))
	}
	if total > 0 {
		parts = append(parts, fmt.Sprintf("total %s", formatCount(total)))
	}
	return strings.Join(parts, ", ")
}

func formatCount(n int) string {
	if n >= 1_000_000 {
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000)
	}
	if n >= 1_000 {
		return fmt.Sprintf("%.1fk", float64(n)/1_000)
	}
	return strconv.Itoa(n)
}

func formatRateLimitsSummary(rl map[string]interface{}) string {
	if rl == nil {
		return "n/a"
	}
	primary := formatRateLimitBucket(asMap(rl["primary"]))
	secondary := formatRateLimitBucket(asMap(rl["secondary"]))

	switch {
	case primary != "" && secondary != "":
		return fmt.Sprintf("primary %s; secondary %s", primary, secondary)
	case primary != "":
		return "primary " + primary
	case secondary != "":
		return "secondary " + secondary
	default:
		return "n/a"
	}
}

func formatRateLimitBucket(bucket map[string]interface{}) string {
	if bucket == nil {
		return ""
	}
	usedPercent := numVal(bucket["usedPercent"])
	windowMins := intVal(bucket["windowDurationMins"])

	if usedPercent >= 0 && windowMins > 0 {
		return fmt.Sprintf("%.0f%% / %dm", usedPercent, windowMins)
	}
	if usedPercent >= 0 {
		return fmt.Sprintf("%.0f%% used", usedPercent)
	}
	return ""
}

func formatReason(message map[string]interface{}) string {
	if reason, ok := getString(message, "reason"); ok {
		return reason
	}
	return compactMap(message)
}

func formatErrorValue(v interface{}) string {
	if m, ok := v.(map[string]interface{}); ok {
		if msg, ok := m["message"].(string); ok {
			return msg
		}
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprintf("%v", v)
}

// --- text helpers ---

var (
	ansiRe    = regexp.MustCompile(`\x1B\[[0-9;]*[A-Za-z]`)
	ansiEscRe = regexp.MustCompile(`\x1B.`)
	controlRe = regexp.MustCompile(`[\x00-\x1F\x7F]`)
	spacesRe  = regexp.MustCompile(`\s+`)
	camelRe   = regexp.MustCompile(`([a-z0-9])([A-Z])`)
)

func sanitizeANSI(s string) string {
	s = ansiRe.ReplaceAllString(s, "")
	s = ansiEscRe.ReplaceAllString(s, "")
	s = controlRe.ReplaceAllString(s, "")
	return s
}

func inlineText(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	s = spacesRe.ReplaceAllString(s, " ")
	s = strings.TrimSpace(s)
	s = sanitizeANSI(s)
	return truncate(s, 80)
}

func truncate(s string, max int) string {
	runes := []rune(s)
	if len(runes) > max {
		return string(runes[:max]) + "..."
	}
	return s
}

func humanizeItemType(t string) string {
	if t == "" {
		return "item"
	}
	t = camelRe.ReplaceAllString(t, "${1} ${2}")
	t = strings.ReplaceAll(t, "_", " ")
	t = strings.ReplaceAll(t, "/", " ")
	return strings.TrimSpace(strings.ToLower(t))
}

func humanizeStatus(s string) string {
	if s == "" {
		return ""
	}
	s = strings.ReplaceAll(s, "_", " ")
	s = strings.ReplaceAll(s, "-", " ")
	return strings.TrimSpace(strings.ToLower(s))
}

func shortID(id string) string {
	if len(id) > 12 {
		return id[:12]
	}
	return id
}

func compactMap(m map[string]interface{}) string {
	s := fmt.Sprintf("%v", m)
	s = strings.ReplaceAll(s, "\n", " ")
	s = sanitizeANSI(s)
	return strings.TrimSpace(s)
}

// --- map traversal helpers ---

func mapPath(m map[string]interface{}, keys ...string) interface{} {
	var current interface{} = m
	for _, k := range keys {
		cm, ok := current.(map[string]interface{})
		if !ok {
			return nil
		}
		current, ok = cm[k]
		if !ok {
			return nil
		}
	}
	return current
}

func mapPathStr(m map[string]interface{}, keys ...string) string {
	v := mapPath(m, keys...)
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func mapPathInt(m map[string]interface{}, keys ...string) int {
	v := mapPath(m, keys...)
	switch val := v.(type) {
	case float64:
		return int(val)
	case int:
		return val
	case string:
		if n, err := strconv.Atoi(strings.TrimSpace(val)); err == nil {
			return n
		}
	}
	return 0
}

func mapPathMap(m map[string]interface{}, keys ...string) map[string]interface{} {
	v := mapPath(m, keys...)
	if mm, ok := v.(map[string]interface{}); ok {
		return mm
	}
	return nil
}

func mapPathSlice(m map[string]interface{}, keys ...string) []interface{} {
	v := mapPath(m, keys...)
	if s, ok := v.([]interface{}); ok {
		return s
	}
	return nil
}

func getString(m map[string]interface{}, key string) (string, bool) {
	v, ok := m[key]
	if !ok {
		return "", false
	}
	s, ok := v.(string)
	return s, ok
}

func firstString(m map[string]interface{}, keys ...string) string {
	for _, k := range keys {
		if s, ok := m[k].(string); ok && s != "" {
			return s
		}
	}
	return ""
}

func asMap(v interface{}) map[string]interface{} {
	if m, ok := v.(map[string]interface{}); ok {
		return m
	}
	return nil
}

func parseIntFromKeys(m map[string]interface{}, keys ...string) int {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			switch val := v.(type) {
			case float64:
				return int(val)
			case int:
				return val
			case string:
				if n, err := strconv.Atoi(strings.TrimSpace(val)); err == nil {
					return n
				}
			}
		}
	}
	return 0
}

func numVal(v interface{}) float64 {
	switch val := v.(type) {
	case float64:
		return val
	case int:
		return float64(val)
	default:
		return -1
	}
}

func intVal(v interface{}) int {
	switch val := v.(type) {
	case float64:
		return int(val)
	case int:
		return val
	default:
		return 0
	}
}

func unwrapPayload(m map[string]interface{}) map[string]interface{} {
	if m == nil {
		return nil
	}
	// If the map already has a "method", "session_id", or "reason" key, use it directly.
	if _, ok := m["method"].(string); ok {
		return m
	}
	if _, ok := m["session_id"].(string); ok {
		return m
	}
	if _, ok := m["reason"].(string); ok {
		return m
	}
	// Otherwise unwrap "payload" sub-key.
	if p := asMap(m["payload"]); p != nil {
		return p
	}
	return m
}
