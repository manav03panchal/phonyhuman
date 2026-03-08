package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type model struct {
	width   int
	height  int
	metrics AgentMetrics
	limits  []RateLimit
	project ProjectInfo
	paused  bool
	panel   int // active panel index for tab switching
}

func demoModel() model {
	return model{
		metrics: AgentMetrics{
			Running:           3,
			MaxAgents:         5,
			FleetStatus:       "running",
			InputTokens:       1_250_000,
			OutputTokens:      380_000,
			CacheReadTokens:   890_000,
			TotalTokens:       2_520_000,
			CacheHitRate:      71.2,
			CostUSD:           4.2847,
			Model:             "claude-sonnet-4-6",
			RuntimeSeconds:    1832,
			TPS:               142.5,
			TPSHistory:        []float64{80, 95, 110, 130, 125, 142, 138, 150, 145, 142, 155, 148, 140, 135, 142, 150, 148, 145, 140, 138, 142, 148, 145, 142},
			LinesChanged:      847,
			Commits:           12,
			PRs:               3,
			ToolCalls:         256,
			ToolAvgDurationMs: 340,
			ToolErrors:        2,
		},
		limits: []RateLimit{
			{Name: "Requests", Used: 42, Limit: 60, ResetInSec: 18},
			{Name: "Tokens", Used: 75000, Limit: 100000, ResetInSec: 45},
			{Name: "Input", Used: 180000, Limit: 200000, ResetInSec: 12},
		},
		project: ProjectInfo{
			LinearURL:    "https://linear.app/humancorp/project/phonyhuman",
			DashboardURL: "http://localhost:4000/dashboard",
			RefreshSec:   10,
		},
	}
}

func (m model) Init() tea.Cmd {
	return nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "tab":
			m.panel = (m.panel + 1) % 3
		case "p":
			m.paused = !m.paused
			if m.paused {
				m.metrics.FleetStatus = "paused"
			} else {
				m.metrics.FleetStatus = "running"
			}
		}
	}
	return m, nil
}

func (m model) View() string {
	if m.width == 0 {
		return "Loading..."
	}

	compact := m.width < 80

	var sections []string

	// Header
	if compact {
		sections = append(sections, renderCompactHeader(m.width))
	} else {
		sections = append(sections, renderHeader(m.width))
	}

	sections = append(sections, "")

	// Metrics panel
	if compact {
		sections = append(sections, renderCompactMetrics(m.metrics, m.width))
	} else {
		sections = append(sections, renderMetricsPanel(m.metrics, m.width))
	}

	sections = append(sections, "")

	// Rate limits
	sections = append(sections, renderRateLimits(m.limits, m.width))

	sections = append(sections, "")

	// Project info
	sections = append(sections, renderProjectInfo(m.project, m.width))

	sections = append(sections, "")

	// Footer
	sections = append(sections, renderFooter(m.width))

	page := lipgloss.JoinVertical(lipgloss.Left, sections...)
	return lipgloss.NewStyle().MaxWidth(m.width).MaxHeight(m.height).Render(page)
}

func main() {
	p := tea.NewProgram(demoModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
