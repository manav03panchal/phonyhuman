package model

import (
	"context"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/humancorp/symphony/tui/client"
	"github.com/humancorp/symphony/tui/types"
	"github.com/humancorp/symphony/tui/view"
)

const pollInterval = 2 * time.Second

// promptMode tracks confirmation dialog state.
type promptMode int

const (
	promptNone promptMode = iota
	promptConfirmPause
	promptConfirmResume
)

// stateMsg carries the result of a state poll.
type stateMsg struct {
	state *types.State
	err   error
}

// fleetActionMsg carries the result of a pause/resume action.
type fleetActionMsg struct {
	err error
}

// tickMsg triggers countdown updates and state re-polls.
type tickMsg time.Time

// Model is the Bubble Tea model for the Symphony TUI dashboard.
type Model struct {
	client  *client.Client
	width   int
	height  int
	state   *types.State
	stateAt time.Time
	prompt  promptMode
	metrics types.AgentMetrics
	limits  []types.RateLimit
	project types.ProjectInfo
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

// Init starts polling and ticking.
func (m Model) Init() tea.Cmd {
	return tea.Batch(pollState(m.client), tickCmd())
}

// Update handles messages.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case tea.KeyMsg:
		return m.handleKey(msg)

	case stateMsg:
		if msg.err == nil && msg.state != nil {
			m.state = msg.state
			m.stateAt = time.Now()
			m.syncMetrics()
		}
		return m, nil

	case fleetActionMsg:
		// Re-poll immediately after fleet action.
		return m, pollState(m.client)

	case tickMsg:
		return m, tea.Batch(pollState(m.client), tickCmd())
	}
	return m, nil
}

// View renders the dashboard.
func (m Model) View() string {
	return view.RenderDashboard(view.DashboardData{
		Width:        m.width,
		Height:       m.height,
		Metrics:      m.metrics,
		Limits:       m.limits,
		Project:      m.project,
		State:        m.state,
		StateAt:      m.stateAt,
		PromptPause:  m.prompt == promptConfirmPause,
		PromptResume: m.prompt == promptConfirmResume,
	})
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()

	// Handle confirmation prompts first.
	if m.prompt == promptConfirmPause {
		switch key {
		case "y", "Y":
			m.prompt = promptNone
			return m, doPause(m.client)
		case "n", "N", "esc":
			m.prompt = promptNone
		}
		return m, nil
	}
	if m.prompt == promptConfirmResume {
		switch key {
		case "y", "Y":
			m.prompt = promptNone
			return m, doResume(m.client)
		case "n", "N", "esc":
			m.prompt = promptNone
		}
		return m, nil
	}

	switch key {
	case "q", "ctrl+c":
		return m, tea.Quit
	case "tab":
		// keep existing tab behavior
	case "p":
		if m.state != nil && m.state.FleetStatus == "paused" {
			m.prompt = promptConfirmResume
		} else {
			m.prompt = promptConfirmPause
		}
	}
	return m, nil
}

// syncMetrics updates the display metrics from the latest API state.
func (m *Model) syncMetrics() {
	s := m.state
	if s == nil {
		return
	}
	m.metrics.FleetStatus = s.FleetStatus
	m.metrics.Running = s.Counts.Running
}

func pollState(c *client.Client) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		state, err := c.FetchState(ctx)
		return stateMsg{state: state, err: err}
	}
}

func doPause(c *client.Client) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		err := c.PauseFleet(ctx, "Manual pause (operator)")
		return fleetActionMsg{err: err}
	}
}

func doResume(c *client.Client) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		err := c.ResumeFleet(ctx)
		return fleetActionMsg{err: err}
	}
}

func tickCmd() tea.Cmd {
	return tea.Tick(pollInterval, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}
