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

// sampleProjectInfo returns project info for testing.
func sampleProjectInfo() types.ProjectInfo {
	return types.ProjectInfo{
		LinearURL:    "https://linear.app/test",
		DashboardURL: "https://dashboard.test",
		RefreshSec:   30,
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

// testWidths are the widths we test at to cover narrow, compact, and full.
var testWidths = []int{0, 1, 3, 10, 20, 30, 40, 60, 80, 120}

func TestRenderHeader_NoPanic(t *testing.T) {
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			got := RenderHeader(w)
			if got == "" && w > 0 {
				t.Errorf("RenderHeader(%d) returned empty string", w)
			}
		})
	}
}

func TestRenderCompactHeader_NoPanic(t *testing.T) {
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			_ = RenderCompactHeader(w)
		})
	}
}

func TestRenderMetricsPanel_NoPanic(t *testing.T) {
	m := sampleMetrics()
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			_ = RenderMetricsPanel(m, w)
		})
	}
}

func TestRenderCompactMetrics_NoPanic(t *testing.T) {
	m := sampleMetrics()
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			_ = RenderCompactMetrics(m, w)
		})
	}
}

func TestRenderRateLimits_NoPanic(t *testing.T) {
	limits := sampleLimits()
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			_ = RenderRateLimits(limits, w)
		})
	}
}

func TestRenderRateLimits_Empty_NoPanic(t *testing.T) {
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			_ = RenderRateLimits(nil, w)
		})
	}
}

func TestRenderRateLimits_CompactBelow60(t *testing.T) {
	limits := sampleLimits()
	// At width < 60, compact layout should be used (no progress bar).
	result := RenderRateLimits(limits, 40)
	if result == "" {
		t.Error("RenderRateLimits(40) returned empty string")
	}
}

func TestRenderProjectInfo_NoPanic(t *testing.T) {
	info := sampleProjectInfo()
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			_ = RenderProjectInfo(info, w)
		})
	}
}

func TestRenderBackoffQueue_NoPanic(t *testing.T) {
	state := sampleState()
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			_ = RenderBackoffQueue(state, w)
		})
	}
}

func TestRenderBackoffQueue_Nil_NoPanic(t *testing.T) {
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			_ = RenderBackoffQueue(nil, w)
		})
	}
}

func TestRenderFooter_NoPanic(t *testing.T) {
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			_ = RenderFooter(w)
		})
	}
}

func TestRenderPrompt_NoPanic(t *testing.T) {
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			_ = RenderPrompt(true, w)
			_ = RenderPrompt(false, w)
		})
	}
}

func TestRenderDashboard_NarrowWidths(t *testing.T) {
	d := DashboardData{
		Height:  50,
		Metrics: sampleMetrics(),
		Limits:  sampleLimits(),
		Project: sampleProjectInfo(),
		State:   sampleState(),
	}
	for _, w := range testWidths {
		t.Run(widthName(w), func(t *testing.T) {
			d.Width = w
			_ = RenderDashboard(d)
		})
	}
}

func TestRenderDashboard_WithPrompt_NarrowWidths(t *testing.T) {
	d := DashboardData{
		Height:      50,
		Metrics:     sampleMetrics(),
		Limits:      sampleLimits(),
		Project:     sampleProjectInfo(),
		State:       sampleState(),
		PromptPause: true,
	}
	for _, w := range []int{30, 40, 80} {
		t.Run(widthName(w), func(t *testing.T) {
			d.Width = w
			_ = RenderDashboard(d)
		})
	}
}

func TestRenderProgressBar_ZeroAndNegativeWidth(t *testing.T) {
	// Should not panic with zero or negative width.
	result := renderProgressBar(0, 0.5)
	if result != "" {
		t.Errorf("renderProgressBar(0, 0.5) = %q, want empty", result)
	}
	result = renderProgressBar(-5, 0.5)
	if result != "" {
		t.Errorf("renderProgressBar(-5, 0.5) = %q, want empty", result)
	}
}

func widthName(w int) string {
	return "width_" + itoa(w)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	s := ""
	neg := false
	if n < 0 {
		neg = true
		n = -n
	}
	for n > 0 {
		s = string(rune('0'+n%10)) + s
		n /= 10
	}
	if neg {
		s = "-" + s
	}
	return s
}
