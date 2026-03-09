package view

import (
	"github.com/charmbracelet/lipgloss"

	"github.com/humancorp/symphony/tui/types"
)

// RenderDashboard returns the full dashboard view string.
func RenderDashboard(width, height int, metrics types.AgentMetrics, limits []types.RateLimit, project types.ProjectInfo) string {
	if width == 0 {
		return "Loading..."
	}

	compact := width < 80

	var sections []string

	// Header
	if compact {
		sections = append(sections, RenderCompactHeader(width))
	} else {
		sections = append(sections, RenderHeader(width))
	}

	sections = append(sections, "")

	// Metrics panel
	if compact {
		sections = append(sections, RenderCompactMetrics(metrics, width))
	} else {
		sections = append(sections, RenderMetricsPanel(metrics, width))
	}

	sections = append(sections, "")

	// Rate limits
	sections = append(sections, RenderRateLimits(limits, width))

	sections = append(sections, "")

	// Project info
	sections = append(sections, RenderProjectInfo(project, width))

	sections = append(sections, "")

	// Footer
	sections = append(sections, RenderFooter(width))

	page := lipgloss.JoinVertical(lipgloss.Left, sections...)
	return lipgloss.NewStyle().MaxWidth(width).MaxHeight(height).Render(page)
}
