package humanize

import (
	"strings"
	"testing"
)

func TestAgentMessage_Nil(t *testing.T) {
	got := AgentMessage(nil)
	if got != "no agent message yet" {
		t.Errorf("nil input: got %q, want %q", got, "no agent message yet")
	}
}

func TestAgentMessage_SessionStarted(t *testing.T) {
	msg := map[string]interface{}{
		"event":   "session_started",
		"message": map[string]interface{}{"session_id": "abc-123"},
	}
	got := AgentMessage(msg)
	if got != "session started (abc-123)" {
		t.Errorf("session_started: got %q, want %q", got, "session started (abc-123)")
	}
}

func TestAgentMessage_TurnInputRequired(t *testing.T) {
	msg := map[string]interface{}{
		"event":   "turn_input_required",
		"message": map[string]interface{}{},
	}
	got := AgentMessage(msg)
	if got != "turn blocked: waiting for user input" {
		t.Errorf("got %q", got)
	}
}

func TestAgentMessage_TurnCancelled(t *testing.T) {
	msg := map[string]interface{}{
		"event":   "turn_cancelled",
		"message": map[string]interface{}{},
	}
	got := AgentMessage(msg)
	if got != "turn cancelled" {
		t.Errorf("got %q", got)
	}
}

func TestAgentMessage_Malformed(t *testing.T) {
	msg := map[string]interface{}{
		"event":   "malformed",
		"message": map[string]interface{}{},
	}
	got := AgentMessage(msg)
	if got != "malformed JSON event from agent" {
		t.Errorf("got %q", got)
	}
}

func TestAgentMessage_TurnStartedMethod(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "turn/started",
			"params": map[string]interface{}{
				"turn": map[string]interface{}{"id": "turn-42"},
			},
		},
	}
	got := AgentMessage(msg)
	if got != "turn started (turn-42)" {
		t.Errorf("got %q, want %q", got, "turn started (turn-42)")
	}
}

func TestAgentMessage_TurnCompletedMethod(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "turn/completed",
			"params": map[string]interface{}{
				"turn": map[string]interface{}{"status": "success"},
				"usage": map[string]interface{}{
					"input_tokens":  float64(1500),
					"output_tokens": float64(500),
					"total_tokens":  float64(2000),
				},
			},
		},
	}
	got := AgentMessage(msg)
	if !strings.Contains(got, "turn completed (success)") {
		t.Errorf("expected 'turn completed (success)' in %q", got)
	}
	if !strings.Contains(got, "in 1.5k") {
		t.Errorf("expected 'in 1.5k' in %q", got)
	}
	if !strings.Contains(got, "out 500") {
		t.Errorf("expected 'out 500' in %q", got)
	}
}

func TestAgentMessage_TurnFailedMethod(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "turn/failed",
			"params": map[string]interface{}{
				"error": map[string]interface{}{"message": "rate limited"},
			},
		},
	}
	got := AgentMessage(msg)
	if got != "turn failed: rate limited" {
		t.Errorf("got %q, want %q", got, "turn failed: rate limited")
	}
}

func TestAgentMessage_ThreadStarted(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "thread/started",
			"params": map[string]interface{}{
				"thread": map[string]interface{}{"id": "th-99"},
			},
		},
	}
	got := AgentMessage(msg)
	if got != "thread started (th-99)" {
		t.Errorf("got %q", got)
	}
}

func TestAgentMessage_TokenUsageUpdated(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "thread/tokenUsage/updated",
			"params": map[string]interface{}{
				"tokenUsage": map[string]interface{}{
					"total": map[string]interface{}{
						"input_tokens":  float64(5000),
						"output_tokens": float64(2000),
						"total_tokens":  float64(7000),
					},
				},
			},
		},
	}
	got := AgentMessage(msg)
	if !strings.Contains(got, "thread token usage updated") {
		t.Errorf("got %q", got)
	}
	if !strings.Contains(got, "in 5.0k") {
		t.Errorf("expected 'in 5.0k' in %q", got)
	}
}

func TestAgentMessage_ItemStarted(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "item/started",
			"params": map[string]interface{}{
				"item": map[string]interface{}{
					"type":   "commandExecution",
					"id":     "item-abcdef123456-extra",
					"status": "in_progress",
				},
			},
		},
	}
	got := AgentMessage(msg)
	if !strings.Contains(got, "item started: command execution") {
		t.Errorf("expected 'item started: command execution' in %q", got)
	}
	if !strings.Contains(got, "item-abcdef1") {
		t.Errorf("expected short ID in %q", got)
	}
}

func TestAgentMessage_ExecCommandBegin(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "codex/event/exec_command_begin",
			"params": map[string]interface{}{
				"msg": map[string]interface{}{
					"command": "npm test",
				},
			},
		},
	}
	got := AgentMessage(msg)
	if got != "npm test" {
		t.Errorf("got %q, want %q", got, "npm test")
	}
}

func TestAgentMessage_ExecCommandEnd(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "codex/event/exec_command_end",
			"params": map[string]interface{}{
				"msg": map[string]interface{}{
					"exit_code": float64(1),
				},
			},
		},
	}
	got := AgentMessage(msg)
	if got != "command completed (exit 1)" {
		t.Errorf("got %q", got)
	}
}

func TestAgentMessage_ExecCommandEndZero(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "codex/event/exec_command_end",
			"params": map[string]interface{}{
				"msg": map[string]interface{}{
					"exit_code": float64(0),
				},
			},
		},
	}
	got := AgentMessage(msg)
	if got != "command completed (exit 0)" {
		t.Errorf("got %q, want %q", got, "command completed (exit 0)")
	}
}

func TestAgentMessage_StreamingDelta(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "item/agentMessage/delta",
			"params": map[string]interface{}{
				"delta": "writing the function...",
			},
		},
	}
	got := AgentMessage(msg)
	if !strings.Contains(got, "agent message streaming: writing the function") {
		t.Errorf("got %q", got)
	}
}

func TestAgentMessage_DynamicToolCall(t *testing.T) {
	msg := map[string]interface{}{
		"event": "tool_call_completed",
		"message": map[string]interface{}{
			"params": map[string]interface{}{
				"tool": "Read",
			},
		},
	}
	got := AgentMessage(msg)
	if got != "dynamic tool call completed (Read)" {
		t.Errorf("got %q", got)
	}
}

func TestAgentMessage_EmptyState(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{},
	}
	got := AgentMessage(msg)
	// Should produce some fallback (compact map)
	if got == "" {
		t.Error("expected non-empty output for empty message payload")
	}
}

func TestAgentMessage_Truncation(t *testing.T) {
	long := strings.Repeat("a", 200)
	msg := map[string]interface{}{
		"event": "turn_ended_with_error",
		"message": map[string]interface{}{
			"reason": long,
		},
	}
	got := AgentMessage(msg)
	if len(got) > maxLen+3 { // 140 + "..."
		t.Errorf("expected truncation, got len=%d", len(got))
	}
	if !strings.HasSuffix(got, "...") {
		t.Errorf("expected '...' suffix in truncated output")
	}
}

func TestTruncate_UTF8(t *testing.T) {
	tests := []struct {
		name  string
		input string
		max   int
		want  string
	}{
		{"emoji within limit", "Hi 🎉🎉", 10, "Hi 🎉🎉"},
		{"emoji truncated", "Hello 🌍🌍🌍", 8, "Hello 🌍🌍..."},
		{"CJK truncated", "中文字符测试内容很长", 5, "中文字符测..."},
		{"CJK within limit", "中文", 5, "中文"},
		{"mixed multi-byte", "abc🎉def中文", 6, "abc🎉de..."},
		{"ascii unchanged", "hello", 10, "hello"},
		{"exact rune boundary", "🎉🎉🎉", 3, "🎉🎉🎉"},
		{"one over rune boundary", "🎉🎉🎉🎉", 3, "🎉🎉🎉..."},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := truncate(tt.input, tt.max)
			if got != tt.want {
				t.Errorf("truncate(%q, %d) = %q, want %q", tt.input, tt.max, got, tt.want)
			}
		})
	}
}

func TestFormatCount(t *testing.T) {
	tests := []struct {
		n    int
		want string
	}{
		{500, "500"},
		{1500, "1.5k"},
		{1000000, "1.0M"},
		{2500000, "2.5M"},
	}
	for _, tt := range tests {
		got := formatCount(tt.n)
		if got != tt.want {
			t.Errorf("formatCount(%d) = %q, want %q", tt.n, got, tt.want)
		}
	}
}

func TestHumanizeItemType(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"", "item"},
		{"commandExecution", "command execution"},
		{"file_change", "file change"},
		{"agent/message", "agent message"},
	}
	for _, tt := range tests {
		got := humanizeItemType(tt.input)
		if got != tt.want {
			t.Errorf("humanizeItemType(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestInlineText(t *testing.T) {
	got := inlineText("hello\n  world\n\nfoo")
	if got != "hello world foo" {
		t.Errorf("got %q", got)
	}
}

func TestAgentMessage_WrappedPayload(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"payload": map[string]interface{}{
				"method": "turn/started",
				"params": map[string]interface{}{
					"turn": map[string]interface{}{"id": "t-1"},
				},
			},
		},
	}
	got := AgentMessage(msg)
	if got != "turn started (t-1)" {
		t.Errorf("got %q, want %q", got, "turn started (t-1)")
	}
}

func TestAgentMessage_McpStartupUpdate(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "codex/event/mcp_startup_update",
			"params": map[string]interface{}{
				"msg": map[string]interface{}{
					"server": "filesystem",
					"status": map[string]interface{}{"state": "running"},
				},
			},
		},
	}
	got := AgentMessage(msg)
	if got != "mcp startup: filesystem running" {
		t.Errorf("got %q", got)
	}
}

func TestAgentMessage_AccountUpdated(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "account/updated",
			"params": map[string]interface{}{
				"authMode": "api_key",
			},
		},
	}
	got := AgentMessage(msg)
	if got != "account updated (auth api_key)" {
		t.Errorf("got %q", got)
	}
}

func TestAgentMessage_PlanUpdated(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "turn/plan/updated",
			"params": map[string]interface{}{
				"plan": []interface{}{"step1", "step2", "step3"},
			},
		},
	}
	got := AgentMessage(msg)
	if got != "plan updated (3 steps)" {
		t.Errorf("got %q", got)
	}
}

func TestAgentMessage_TokenCountWrapper(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"method": "codex/event/token_count",
			"params": map[string]interface{}{
				"tokenUsage": map[string]interface{}{
					"total": map[string]interface{}{
						"input_tokens":  float64(10000),
						"output_tokens": float64(3000),
						"total_tokens":  float64(13000),
					},
				},
			},
		},
	}
	got := AgentMessage(msg)
	if !strings.Contains(got, "token count update") {
		t.Errorf("got %q", got)
	}
	if !strings.Contains(got, "in 10.0k") {
		t.Errorf("expected 'in 10.0k' in %q", got)
	}
}

func TestAgentMessage_ErrorPayload(t *testing.T) {
	msg := map[string]interface{}{
		"message": map[string]interface{}{
			"error": map[string]interface{}{"message": "connection refused"},
		},
	}
	got := AgentMessage(msg)
	if got != "error: connection refused" {
		t.Errorf("got %q", got)
	}
}
