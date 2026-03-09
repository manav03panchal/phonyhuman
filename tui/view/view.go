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
	PromptPause  bool
	PromptResume bool
}

// RenderDashboard returns the full dashboard view string.
func RenderDashboard(d DashboardData) string {
	if d.Width == 0 {
		return "Loading..."
	}

	compact := d.Width < 80

	var sections []string

	// Header
	if compact {
		sections = append(sections, RenderCompactHeader(d.Width))
	} else {
		sections = append(sections, RenderHeader(d.Width))
	}

	sections = append(sections, "")

	// Metrics panel
	if compact {
		sections = append(sections, RenderCompactMetrics(d.Metrics, d.Width))
	} else {
		sections = append(sections, RenderMetricsPanel(d.Metrics, d.Width))
	}

	sections = append(sections, "")

	// Rate limits
	sections = append(sections, RenderRateLimits(d.Limits, d.Width))

	sections = append(sections, "")

	// Backoff queue panel
	sections = append(sections, RenderBackoffQueue(d.State, d.Width))

	sections = append(sections, "")

	// Project info
	sections = append(sections, RenderProjectInfo(d.Project, d.Width))

	sections = append(sections, "")

	// Prompt (if active)
	if d.PromptPause || d.PromptResume {
		sections = append(sections, RenderPrompt(d.PromptPause, d.Width))
		sections = append(sections, "")
	}

	// Footer
	sections = append(sections, RenderFooter(d.Width))

	page := lipgloss.JoinVertical(lipgloss.Left, sections...)
	return lipgloss.NewStyle().MaxWidth(d.Width).MaxHeight(d.Height).Render(page)
}
