package view

import (
	"time"

	"github.com/charmbracelet/lipgloss"

	"github.com/humancorp/symphony/tui/types"
)

// DashboardData holds all data needed for the main dashboard render.
type DashboardData struct {
	Width        int
	Height       int
	Metrics      types.AgentMetrics
	Limits       []types.RateLimit
	Project      types.ProjectInfo
	State        *types.State
	StateAt      time.Time
	Agents       []types.Agent
	PromptPause  bool
	PromptResume bool
}

// RenderDashboard returns the full k9s-style dashboard view.
func RenderDashboard(d DashboardData) string {
	if d.Width == 0 {
		return "Loading..."
	}

	w := d.Width

	// Line 1: logo + breadcrumb
	header := RenderCrumbBar(d.Metrics, w)

	// Line 2: compact metrics bar
	metrics := RenderMetricsBar(d.Metrics, d.Limits, w)

	// Footer (bottom line)
	footer := RenderFooter(w)

	// Prompt overlay (if active)
	promptLine := ""
	if d.PromptPause || d.PromptResume {
		promptLine = RenderPrompt(d.PromptPause, w)
	}

	// Calculate remaining height for the table
	usedLines := 4 // header + metrics + blank + footer
	if promptLine != "" {
		usedLines++
	}

	// Backoff queue (only if entries exist)
	backoff := ""
	if d.State != nil && len(d.State.Retrying) > 0 {
		backoff = RenderBackoffQueue(d.State, w)
		usedLines += lipgloss.Height(backoff) + 1
	}

	tableHeight := d.Height - usedLines
	if tableHeight < 3 {
		tableHeight = 3
	}

	// Main content: agents table fills remaining space
	table := RenderAgentsTable(d.Agents, w, tableHeight)

	// Assemble
	var sections []string
	sections = append(sections, header)
	sections = append(sections, metrics)
	sections = append(sections, table)
	if backoff != "" {
		sections = append(sections, backoff)
	}
	if promptLine != "" {
		sections = append(sections, promptLine)
	}
	sections = append(sections, footer)

	page := lipgloss.JoinVertical(lipgloss.Left, sections...)
	return lipgloss.NewStyle().MaxWidth(w).MaxHeight(d.Height).Render(page)
}
