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
	promptConfirmQuit
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
	cursor  int
	stateAt time.Time
	prompt  promptMode
	metrics types.AgentMetrics
	limits  []types.RateLimit
	project types.ProjectInfo
	agents  []types.Agent

	// Lifecycle context — cancelled on model teardown to stop SSE/poll goroutines.
	ctx    context.Context
	cancel context.CancelFunc

	// SSE / polling state
	state    *types.State
	stateErr error
	useSSE   bool
	sseSub   *client.SSESubscription

	// Fleet action error — set when pause/resume fails, cleared on next
	// successful state poll.
	lastActionErr error
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
			m.lastActionErr = nil
			m.syncMetrics()
		}
		if m.useSSE && m.sseSub != nil {
			return m, waitForSSE(m.sseSub)
		}
		return m, nil

	case fleetActionMsg:
		m.lastActionErr = msg.err
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
		Agents:       m.agents,
		SelectedRow:  m.cursor,
		PromptPause:  m.prompt == promptConfirmPause,
		PromptResume: m.prompt == promptConfirmResume,
		PromptQuit:   m.prompt == promptConfirmQuit,
		ActionErr:    m.lastActionErr,
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
	if m.prompt == promptConfirmQuit {
		switch key {
		case "y", "Y":
			m.cancel()
			if m.sseSub != nil {
				m.sseSub.Close()
			}
			return m, tea.Quit
		case "n", "N", "esc":
			m.prompt = promptNone
		}
		return m, nil
	}

	switch key {
	case "q", "ctrl+c":
		m.prompt = promptConfirmQuit
	case "j", "down":
		if len(m.agents) > 0 {
			m.cursor++
			if m.cursor >= len(m.agents) {
				m.cursor = len(m.agents) - 1
			}
		}
	case "k", "up":
		if m.cursor > 0 {
			m.cursor--
		}
	case "enter":
		if len(m.agents) > 0 && m.cursor < len(m.agents) {
			return m, func() tea.Msg {
				return types.AgentSelectedMsg{Agent: m.agents[m.cursor]}
			}
		}
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

	// Token metrics — only show when agents are active
	if s.Counts.Running > 0 {
		m.metrics.InputTokens = int64(t.InputTokens)
		m.metrics.OutputTokens = int64(t.OutputTokens)
		m.metrics.CacheReadTokens = int64(t.CacheReadTokens)
		m.metrics.TotalTokens = int64(t.TotalTokens)
		m.metrics.CacheHitRate = t.CacheHitRate
		m.metrics.CostUSD = t.CostUSD
		if t.Model != nil {
			m.metrics.Model = *t.Model
		} else {
			m.metrics.Model = ""
		}
	} else {
		m.metrics.InputTokens = 0
		m.metrics.OutputTokens = 0
		m.metrics.CacheReadTokens = 0
		m.metrics.TotalTokens = 0
		m.metrics.CacheHitRate = 0
		m.metrics.CostUSD = 0
		m.metrics.Model = ""
	}

	// Runtime — use wall clock elapsed from earliest agent when backend reports 0
	m.metrics.RuntimeSeconds = t.SecondsRunning
	if t.SecondsRunning == 0 && s.Counts.Running > 0 {
		var earliest time.Time
		for _, e := range s.Running {
			if e.StartedAt != nil {
				if ts, err := time.Parse(time.RFC3339, *e.StartedAt); err == nil {
					if earliest.IsZero() || ts.Before(earliest) {
						earliest = ts
					}
				}
			}
		}
		if !earliest.IsZero() {
			m.metrics.RuntimeSeconds = int(time.Since(earliest).Seconds())
		}
	}

	// TPS
	if s.Counts.Running > 0 && m.metrics.RuntimeSeconds > 0 && t.TotalTokens > 0 {
		tps := float64(t.TotalTokens) / float64(m.metrics.RuntimeSeconds)
		m.metrics.TPS = tps
		m.metrics.TPSHistory = append(m.metrics.TPSHistory, tps)
		if len(m.metrics.TPSHistory) > 24 {
			m.metrics.TPSHistory = m.metrics.TPSHistory[len(m.metrics.TPSHistory)-24:]
		}
	} else {
		m.metrics.TPS = 0
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

	// Per-agent display models + compute total agent time
	m.agents = m.agents[:0]
	totalAgentSec := 0
	for _, e := range s.Running {
		started := time.Time{}
		if e.StartedAt != nil {
			if ts, err := time.Parse(time.RFC3339, *e.StartedAt); err == nil {
				started = ts
			}
		}
		status := types.StatusActive
		if e.State == "error" {
			status = types.StatusError
		}
		lastEvent := ""
		if e.LastEvent != nil {
			lastEvent = *e.LastEvent
		} else if e.LastMessage != nil {
			lastEvent = *e.LastMessage
		}
		model := ""
		if e.Model != nil {
			model = *e.Model
		}

		// Per-agent elapsed: use active_time_seconds if available, else wall clock
		agentElapsed := e.ActiveTimeSeconds
		if agentElapsed == 0 && !started.IsZero() {
			agentElapsed = int(time.Since(started).Seconds())
		}
		totalAgentSec += agentElapsed

		m.agents = append(m.agents, types.Agent{
			ID:              e.IssueIdentifier,
			Stage:           e.State,
			StartedAt:       started,
			InputTokens:     e.Tokens.InputTokens,
			OutputTokens:    e.Tokens.OutputTokens,
			CacheReadTokens: e.Tokens.CacheReadTokens,
			CostUSD:         e.Tokens.CostUSD,
			Model:           model,
			SessionID:       e.SessionID,
			Status:          status,
			LastEventStr:    lastEvent,
			ToolCalls:       e.ToolCalls,
			LinesChanged:    e.LinesChanged,
		})
	}
	m.metrics.AgentTimeSeconds = totalAgentSec

	// Clamp cursor after agent list changes
	if m.cursor >= len(m.agents) && len(m.agents) > 0 {
		m.cursor = len(m.agents) - 1
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
