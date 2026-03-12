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

// stateMsg carries the result of a state fetch (SSE or poll).
type stateMsg struct {
	state *types.State
	err   error
}

// fleetActionMsg carries the result of a pause/resume action.
type fleetActionMsg struct {
	err error
}

// sseClosedMsg signals the SSE subscription ended (404 or terminal error).
type sseClosedMsg struct{}

// pollTickMsg triggers a periodic state poll.
type pollTickMsg struct{}

// tickMsg triggers countdown updates.
type tickMsg time.Time

// pollTimeout is the per-request timeout for HTTP state polls.
const pollTimeout = 10 * time.Second

// Model is the Bubble Tea model for the Symphony TUI dashboard.
type Model struct {
	client  *client.Client
	width   int
	height  int
	stateAt time.Time
	prompt  promptMode
	metrics types.AgentMetrics
	limits  []types.RateLimit
	project types.ProjectInfo

	// Lifecycle context — cancelled on model teardown to stop SSE/poll goroutines.
	ctx    context.Context
	cancel context.CancelFunc

	// SSE / polling state
	state    *types.State
	stateErr error
	useSSE   bool
	sseSub   *client.SSESubscription
}

// New creates a Model wired to the given API client.
// It eagerly creates an SSE subscription so the pointer is shared across
// Bubble Tea's value copies of the model.
func New(c *client.Client) Model {
	ctx, cancel := context.WithCancel(context.Background())
	return Model{
		client: c,
		metrics: types.AgentMetrics{
			FleetStatus: "running",
		},
		project: types.ProjectInfo{
			DashboardURL: c.BaseURL(),
			RefreshSec:   10,
		},
		ctx:    ctx,
		cancel: cancel,
		useSSE: true,
		sseSub: c.SubscribeSSE(ctx),
	}
}

// Init starts listening for SSE events and ticking for countdown updates.
func (m Model) Init() tea.Cmd {
	return tea.Batch(waitForSSE(m.sseSub), tickCmd())
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
		if msg.err != nil {
			m.stateErr = msg.err
		} else {
			m.state = msg.state
			m.stateAt = time.Now()
			m.stateErr = nil
			m.syncMetrics()
		}
		if m.useSSE && m.sseSub != nil {
			return m, waitForSSE(m.sseSub)
		}
		return m, nil

	case fleetActionMsg:
		// Re-poll immediately after fleet action.
		return m, m.pollState()

	case sseClosedMsg:
		// SSE unavailable (404 or terminal) — fall back to polling.
		m.useSSE = false
		m.sseSub = nil
		return m, tea.Batch(m.pollState(), schedulePoll())

	case pollTickMsg:
		if m.useSSE {
			return m, nil
		}
		return m, tea.Batch(m.pollState(), schedulePoll())

	case tickMsg:
		return m, tickCmd()
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
		m.cancel()
		if m.sseSub != nil {
			m.sseSub.Close()
		}
		return m, tea.Quit
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

	t := s.AgentTotals

	m.metrics.FleetStatus = s.FleetStatus
	m.metrics.Running = s.Counts.Running
	if s.MaxAgents > 0 {
		m.metrics.MaxAgents = s.MaxAgents
	}

	// Token metrics
	m.metrics.InputTokens = int64(t.InputTokens)
	m.metrics.OutputTokens = int64(t.OutputTokens)
	m.metrics.CacheReadTokens = int64(t.CacheReadTokens)
	m.metrics.TotalTokens = int64(t.TotalTokens)
	m.metrics.CacheHitRate = t.CacheHitRate
	m.metrics.CostUSD = t.CostUSD
	if t.Model != nil {
		m.metrics.Model = *t.Model
	}

	// Runtime & TPS
	m.metrics.RuntimeSeconds = t.SecondsRunning
	if t.SecondsRunning > 0 {
		tps := float64(t.TotalTokens) / float64(t.SecondsRunning)
		m.metrics.TPS = tps
		// Append to sparkline history (keep last 24 points)
		m.metrics.TPSHistory = append(m.metrics.TPSHistory, tps)
		if len(m.metrics.TPSHistory) > 24 {
			m.metrics.TPSHistory = m.metrics.TPSHistory[len(m.metrics.TPSHistory)-24:]
		}
	}

	// Code stats
	m.metrics.LinesChanged = t.LinesChanged
	m.metrics.Commits = t.CommitsCount
	m.metrics.PRs = t.PRsCount

	// Tool stats
	m.metrics.ToolCalls = t.ToolCalls
	m.metrics.ToolAvgDurationMs = t.ToolAvgDurationMs
	m.metrics.ToolErrors = t.APIErrors

	// Rate limits
	m.limits = m.limits[:0]
	if s.RateLimits != nil {
		rl := s.RateLimits
		if rl.PrimaryBucket != nil {
			m.limits = append(m.limits, types.RateLimit{
				Name:  "Primary",
				Used:  rl.PrimaryBucket.Capacity - rl.PrimaryBucket.Remaining,
				Limit: rl.PrimaryBucket.Capacity,
			})
		}
		if rl.SecondaryBucket != nil {
			m.limits = append(m.limits, types.RateLimit{
				Name:  "Secondary",
				Used:  rl.SecondaryBucket.Capacity - rl.SecondaryBucket.Remaining,
				Limit: rl.SecondaryBucket.Capacity,
			})
		}
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

// waitForSSE returns a Cmd that blocks until the next SSE event arrives.
// When the event channel closes it returns sseClosedMsg to trigger polling fallback.
func waitForSSE(sub *client.SSESubscription) tea.Cmd {
	return func() tea.Msg {
		event, ok := <-sub.Events()
		if !ok {
			return sseClosedMsg{}
		}
		state, err := client.ParseStateEvent(event.Data)
		return stateMsg{state: state, err: err}
	}
}

// pollState fetches state via HTTP GET with a bounded timeout.
func (m Model) pollState() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(m.ctx, pollTimeout)
		defer cancel()
		state, err := m.client.FetchState(ctx)
		return stateMsg{state: state, err: err}
	}
}

// schedulePoll returns a Cmd that sends a pollTickMsg after the poll interval.
func schedulePoll() tea.Cmd {
	return tea.Tick(pollInterval, func(time.Time) tea.Msg {
		return pollTickMsg{}
	})
}
