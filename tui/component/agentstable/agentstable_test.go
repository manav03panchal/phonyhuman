package agentstable

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/humancorp/symphony/tui/types"
)

func sampleAgents() []types.Agent {
	return []types.Agent{
		{
			ID:        "agent-bravo",
			Stage:     "executing",
			PID:       "12345",
			StartedAt: time.Now().Add(-2 * time.Minute),
			Turn:      3,
			Tokens:    15000,
			SessionID: "sess-abc",
			Status:    types.StatusActive,
			LastEvent: map[string]interface{}{
				"message": map[string]interface{}{
					"method": "turn/started",
					"params": map[string]interface{}{
						"turn": map[string]interface{}{"id": "t-5"},
					},
				},
			},
		},
		{
			ID:        "agent-alpha",
			Stage:     "planning",
			PID:       "12340",
			StartedAt: time.Now().Add(-5 * time.Minute),
			Turn:      1,
			Tokens:    3500,
			SessionID: "sess-xyz",
			Status:    types.StatusTurnComplete,
			LastEvent: map[string]interface{}{
				"message": map[string]interface{}{
					"method": "turn/completed",
					"params": map[string]interface{}{
						"turn": map[string]interface{}{"status": "success"},
					},
				},
			},
		},
	}
}

func TestNew(t *testing.T) {
	m := New()
	if m.table.Focused() != true {
		t.Error("table should be focused by default")
	}
}

func TestEmptyView(t *testing.T) {
	m := New()
	view := m.View()
	if !strings.Contains(view, "No active agents") {
		t.Errorf("empty view should contain 'No active agents', got: %q", view)
	}
}

func TestUpdateWithAgents(t *testing.T) {
	m := New()
	agents := sampleAgents()

	updated, _ := m.Update(types.AgentsUpdatedMsg{Agents: agents})
	view := updated.View()

	// Should NOT show empty state
	if strings.Contains(view, "No active agents") {
		t.Error("view should not show empty state when agents are present")
	}

	// Should show agent data (agents are sorted by ID, so agent-alpha first)
	if !strings.Contains(view, "agent-alpha") {
		t.Errorf("view should contain 'agent-alpha', got:\n%s", view)
	}
	if !strings.Contains(view, "agent-bravo") {
		t.Errorf("view should contain 'agent-bravo', got:\n%s", view)
	}
}

func TestRowsSortedByID(t *testing.T) {
	agents := sampleAgents()
	rows := buildRows(agents)

	if len(rows) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(rows))
	}

	// First row should be agent-alpha (sorted alphabetically)
	if !strings.Contains(rows[0][0], "agent-alpha") {
		t.Errorf("first row ID should contain 'agent-alpha', got %q", rows[0][0])
	}
	if !strings.Contains(rows[1][0], "agent-bravo") {
		t.Errorf("second row ID should contain 'agent-bravo', got %q", rows[1][0])
	}
}

func TestStatusDotColors(t *testing.T) {
	tests := []struct {
		status types.AgentStatus
		color  string
	}{
		{types.StatusActive, "42"},
		{types.StatusTokenUpdate, "220"},
		{types.StatusTurnComplete, "212"},
		{types.StatusError, "196"},
		{types.StatusDefault, "69"},
	}
	for _, tt := range tests {
		got := tt.status.StatusColor()
		if got != tt.color {
			t.Errorf("StatusColor(%s) = %q, want %q", tt.status, got, tt.color)
		}
	}
}

func TestFormatAge(t *testing.T) {
	now := time.Now()
	tests := []struct {
		started time.Time
		want    string
	}{
		{time.Time{}, "—"},
		{now.Add(-30 * time.Second), "30s"},
		{now.Add(-90 * time.Second), "1m30s"},
		{now.Add(-90 * time.Minute), "1h30m"},
	}
	for _, tt := range tests {
		got := formatAge(tt.started)
		if got != tt.want {
			t.Errorf("formatAge(%v) = %q, want %q", tt.started, got, tt.want)
		}
	}
}

func TestFormatTokens(t *testing.T) {
	tests := []struct {
		tokens int
		want   string
	}{
		{0, "—"},
		{500, "500"},
		{1500, "1.5k"},
		{1500000, "1.5M"},
	}
	for _, tt := range tests {
		got := formatTokens(tt.tokens)
		if got != tt.want {
			t.Errorf("formatTokens(%d) = %q, want %q", tt.tokens, got, tt.want)
		}
	}
}

func TestTruncateStr(t *testing.T) {
	tests := []struct {
		input string
		max   int
		want  string
	}{
		{"short", 10, "short"},
		{"this is a long string", 10, "this is..."},
		{"ab", 2, "ab"},
	}
	for _, tt := range tests {
		got := truncateStr(tt.input, tt.max)
		if got != tt.want {
			t.Errorf("truncateStr(%q, %d) = %q, want %q", tt.input, tt.max, got, tt.want)
		}
	}
}

func TestTruncateStr_UTF8(t *testing.T) {
	tests := []struct {
		name  string
		input string
		max   int
		want  string
	}{
		{"emoji within limit", "Hi 🎉", 10, "Hi 🎉"},
		{"emoji truncated", "Hello 🌍🌍🌍🌍🌍", 10, "Hello 🌍..."},
		{"CJK truncated", "中文字符测试内容很长", 7, "中文字符..."},
		{"CJK within limit", "中文", 5, "中文"},
		{"mixed multi-byte", "abc🎉def中文gh", 8, "abc🎉d..."},
		{"max <= 3 with emoji", "🎉🎉🎉🎉", 3, "🎉🎉🎉"},
		{"max <= 3 truncated", "🎉🎉🎉🎉🎉", 2, "🎉🎉"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := truncateStr(tt.input, tt.max)
			if got != tt.want {
				t.Errorf("truncateStr(%q, %d) = %q, want %q", tt.input, tt.max, got, tt.want)
			}
		})
	}
}

func TestEnterKeyEmitsAgentSelected(t *testing.T) {
	m := New()
	agents := sampleAgents()

	// Update with agents
	m, _ = m.Update(types.AgentsUpdatedMsg{Agents: agents})

	// Press enter
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected a command from Enter key press")
	}

	// Execute the command to get the message
	msg := cmd()
	selected, ok := msg.(types.AgentSelectedMsg)
	if !ok {
		t.Fatalf("expected AgentSelectedMsg, got %T", msg)
	}

	// Should select the first sorted agent (agent-alpha)
	if selected.Agent.ID != "agent-alpha" {
		t.Errorf("expected agent-alpha, got %q", selected.Agent.ID)
	}
}

func TestEnterKeyOnEmptyTable(t *testing.T) {
	m := New()
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd != nil {
		t.Error("Enter on empty table should not emit a command")
	}
}

func TestSetSize(t *testing.T) {
	m := New()
	m.SetSize(120, 30)
	if m.width != 120 || m.height != 30 {
		t.Errorf("expected width=120 height=30, got width=%d height=%d", m.width, m.height)
	}
	if !m.ready {
		t.Error("expected ready=true after SetSize")
	}
}

func TestFocusBlur(t *testing.T) {
	m := New()
	if !m.Focused() {
		t.Error("should be focused by default")
	}
	m.Blur()
	if m.Focused() {
		t.Error("should not be focused after Blur")
	}
	m.Focus()
	if !m.Focused() {
		t.Error("should be focused after Focus")
	}
}

func TestHumanizedEventInRow(t *testing.T) {
	a := types.Agent{
		ID:    "ag-1",
		Stage: "idle",
		PID:   "999",
		Turn:  1,
		LastEvent: map[string]interface{}{
			"event":   "turn_cancelled",
			"message": map[string]interface{}{},
		},
	}
	row := agentRow(a)
	lastEvent := row[7]
	if lastEvent != "turn cancelled" {
		t.Errorf("expected humanized event 'turn cancelled', got %q", lastEvent)
	}
}

func TestEmptyViewWithDimensions(t *testing.T) {
	m := New()
	m.SetSize(80, 24)
	view := m.View()
	if !strings.Contains(view, "No active agents") {
		t.Errorf("expected 'No active agents' in sized empty view")
	}
}
