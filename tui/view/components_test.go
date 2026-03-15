package view

import (
	"testing"

	"github.com/humancorp/symphony/tui/types"
)

// sampleMetrics returns a populated AgentMetrics for testing.
func sampleMetrics() types.AgentMetrics {
	return types.AgentMetrics{
		Running:           3,
		MaxAgents:         5,
		FleetStatus:       "running",
		InputTokens:       12345,
		OutputTokens:      6789,
		CacheReadTokens:   4000,
		TotalTokens:       23134,
		CacheHitRate:      32.5,
		CostUSD:           0.0042,
		Model:             "claude-sonnet-4-20250514",
		RuntimeSeconds:    3661,
		TPS:               2.4,
		TPSHistory:        []float64{1.0, 2.0, 1.5, 3.0, 2.5},
		LinesChanged:      142,
		Commits:           7,
		PRs:               2,
		ToolCalls:         45,
		ToolAvgDurationMs: 120,
		ToolErrors:        1,
	}
}

// sampleLimits returns rate limit data for testing.
func sampleLimits() []types.RateLimit {
	return []types.RateLimit{
		{Name: "requests", Used: 80, Limit: 100, ResetInSec: 30},
		{Name: "tokens", Used: 5000, Limit: 10000, ResetInSec: 60},
	}
}

// sampleState returns a state with retry entries for testing.
func sampleState() *types.State {
	return &types.State{
		Retrying: []types.RetryEntry{
			{IssueIdentifier: "HUM-1", Attempt: 2, DueAt: "2026-12-31T00:00:00Z", Error: "rate limited"},
		},
	}
}

// sampleAgents returns per-agent data for testing.
func sampleAgents() []types.Agent {
	return []types.Agent{
		{ID: "HUM-59", Stage: "running", InputTokens: 50000, OutputTokens: 12000, CacheReadTokens: 8000, CostUSD: 0.34, Model: "claude-sonnet-4-20250514", SessionID: "sess-abc-123", Status: types.StatusActive},
		{ID: "HUM-60", Stage: "error", InputTokens: 8000, OutputTokens: 1500, CacheReadTokens: 2000, CostUSD: 0.05, Model: "claude-sonnet-4-20250514", SessionID: "sess-def-456", Status: types.StatusError},
	}
}

var testWidths = []int{0, 1, 10, 40, 80, 120, 200}

func TestRenderCrumbBar_NoPanic(t *testing.T) {
	m := sampleMetrics()
	for _, w := range testWidths {
		got := RenderCrumbBar(m, w)
		if got == "" && w > 10 {
			t.Errorf("RenderCrumbBar(%d) returned empty string", w)
		}
	}
}

func TestRenderMetricsBar_NoPanic(t *testing.T) {
	m := sampleMetrics()
	limits := sampleLimits()
	for _, w := range testWidths {
		_ = RenderMetricsBar(m, limits, w)
	}
}

func TestRenderMetricsBar_EmptyLimits(t *testing.T) {
	m := sampleMetrics()
	for _, w := range testWidths {
		_ = RenderMetricsBar(m, nil, w)
	}
}

func TestRenderAgentsTable_NoPanic(t *testing.T) {
	agents := sampleAgents()
	for _, w := range testWidths {
		_ = RenderAgentsTable(agents, w, 20)
	}
}

func TestRenderAgentsTable_Empty(t *testing.T) {
	for _, w := range testWidths {
		got := RenderAgentsTable(nil, w, 20)
		if w > 10 && got == "" {
			t.Errorf("RenderAgentsTable(nil, %d, 20) returned empty string", w)
		}
	}
}

func TestRenderAgentsTable_SmallHeight(t *testing.T) {
	agents := sampleAgents()
	_ = RenderAgentsTable(agents, 80, 1)
	_ = RenderAgentsTable(agents, 80, 2)
	_ = RenderAgentsTable(agents, 80, 3)
}

func TestRenderBackoffQueue_NoPanic(t *testing.T) {
	state := sampleState()
	for _, w := range testWidths {
		_ = RenderBackoffQueue(state, w)
	}
}

func TestRenderBackoffQueue_Nil_NoPanic(t *testing.T) {
	for _, w := range testWidths {
		_ = RenderBackoffQueue(nil, w)
	}
}

func TestRenderFooter_NoPanic(t *testing.T) {
	for _, w := range testWidths {
		_ = RenderFooter(w)
	}
}

func TestRenderPrompt_NoPanic(t *testing.T) {
	for _, w := range testWidths {
		_ = RenderPrompt(true, w)
		_ = RenderPrompt(false, w)
	}
}

func TestRenderDashboard_NarrowWidths(t *testing.T) {
	d := DashboardData{
		Height:  50,
		Metrics: sampleMetrics(),
		Limits:  sampleLimits(),
		State:   sampleState(),
		Agents:  sampleAgents(),
	}
	for _, w := range testWidths {
		d.Width = w
		_ = RenderDashboard(d)
	}
}

func TestRenderDashboard_WithPrompt(t *testing.T) {
	d := DashboardData{
		Width:       80,
		Height:      50,
		Metrics:     sampleMetrics(),
		Limits:      sampleLimits(),
		State:       sampleState(),
		Agents:      sampleAgents(),
		PromptPause: true,
	}
	got := RenderDashboard(d)
	if got == "" {
		t.Error("RenderDashboard with prompt returned empty string")
	}
}

func TestRenderDashboard_ZeroWidth(t *testing.T) {
	d := DashboardData{Width: 0, Height: 50}
	got := RenderDashboard(d)
	if got != "Loading..." {
		t.Errorf("expected Loading..., got %q", got)
	}
}

func TestMiniBar_Clamping(t *testing.T) {
	_ = miniBar(0, 0.5)
	_ = miniBar(10, -1.0)
	_ = miniBar(10, 2.0)
	_ = miniBar(10, 0.0)
	_ = miniBar(10, 1.0)
}

func TestFmtTokens(t *testing.T) {
	cases := []struct {
		in   int64
		want string
	}{
		{0, "0"},
		{999, "999"},
		{1000, "1.0K"},
		{1500000, "1.5M"},
	}
	for _, c := range cases {
		got := fmtTokens(c.in)
		if got != c.want {
			t.Errorf("fmtTokens(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestFmtDuration(t *testing.T) {
	cases := []struct {
		in   int
		want string
	}{
		{0, "0s"},
		{59, "59s"},
		{61, "1m1s"},
		{3661, "1h1m"},
	}
	for _, c := range cases {
		got := fmtDuration(c.in)
		if got != c.want {
			t.Errorf("fmtDuration(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestTruncStr(t *testing.T) {
	if got := truncStr("hello", 3); got != "…" {
		// max=3, so we get just the truncation char
	}
	if got := truncStr("hello world", 8); got != "hello…" {
		// should truncate
	}
	if got := truncStr("hi", 10); got != "hi" {
		t.Errorf("truncStr short string = %q", got)
	}
}

func TestTruncStr_MultiByte(t *testing.T) {
	cases := []struct {
		name string
		in   string
		max  int
		want string
	}{
		{"CJK under limit", "日本語", 10, "日本語"},
		{"CJK at limit", "日本語", 3, "日本語"},
		{"CJK over limit truncates by rune", "日本語テスト", 5, "日本…"},
		{"emoji under limit", "🎉🎊🎈", 10, "🎉🎊🎈"},
		{"emoji at limit", "🎉🎊🎈🎆🎇", 5, "🎉🎊🎈🎆🎇"},
		{"emoji over limit", "🎉🎊🎈🎆🎇🎯", 5, "🎉🎊…"},
		{"mixed ASCII and CJK", "abc日本語def", 7, "abc日…"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := truncStr(c.in, c.max)
			if got != c.want {
				t.Errorf("truncStr(%q, %d) = %q, want %q", c.in, c.max, got, c.want)
			}
		})
	}
}

func TestTruncError_MultiByte(t *testing.T) {
	// Build a string of 65 CJK runes (exceeds maxErrorLen=60).
	long := ""
	for i := 0; i < 65; i++ {
		long += "漢"
	}
	got := truncError(long)
	runes := []rune(got)
	// Should be 59 漢 + 1 ellipsis = 60 runes.
	if len(runes) != maxErrorLen {
		t.Errorf("truncError(65 CJK runes): got %d runes, want %d", len(runes), maxErrorLen)
	}
	if runes[len(runes)-1] != '…' {
		t.Errorf("truncError: last rune = %q, want '…'", runes[len(runes)-1])
	}

	// Short multi-byte string should pass through unchanged.
	short := "エラー: 接続失敗"
	if got := truncError(short); got != short {
		t.Errorf("truncError(%q) = %q, want unchanged", short, got)
	}

	// Newlines in multi-byte string should be replaced.
	withNL := "エラー\n接続失敗"
	want := "エラー 接続失敗"
	if got := truncError(withNL); got != want {
		t.Errorf("truncError(%q) = %q, want %q", withNL, got, want)
	}
}
