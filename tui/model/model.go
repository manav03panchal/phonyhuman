package model

import (
	tea "github.com/charmbracelet/bubbletea"

	"github.com/humancorp/symphony/tui/client"
	"github.com/humancorp/symphony/tui/types"
	"github.com/humancorp/symphony/tui/view"
)

// Model is the Bubble Tea model for the Symphony TUI dashboard.
type Model struct {
	client  *client.Client
	width   int
	height  int
	metrics types.AgentMetrics
	limits  []types.RateLimit
	project types.ProjectInfo
	paused  bool
	panel   int // active panel index for tab switching
}

// New creates a Model wired to the given API client with demo data.
func New(c *client.Client) Model {
	return Model{
		client: c,
		metrics: types.AgentMetrics{
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
		limits: []types.RateLimit{
			{Name: "Requests", Used: 42, Limit: 60, ResetInSec: 18},
			{Name: "Tokens", Used: 75000, Limit: 100000, ResetInSec: 45},
			{Name: "Input", Used: 180000, Limit: 200000, ResetInSec: 12},
		},
		project: types.ProjectInfo{
			LinearURL:    "https://linear.app/humancorp/project/phonyhuman",
			DashboardURL: "http://localhost:4000/dashboard",
			RefreshSec:   10,
		},
	}
}

// Init returns no initial command.
func (m Model) Init() tea.Cmd {
	return nil
}

// Update handles messages.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
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

// View renders the dashboard.
func (m Model) View() string {
	return view.RenderDashboard(m.width, m.height, m.metrics, m.limits, m.project)
}
