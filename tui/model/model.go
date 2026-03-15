package model

import (
	"context"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/humancorp/symphony/tui/client"
	"github.com/humancorp/symphony/tui/types"
	"github.com/humancorp/symphony/tui/view"
)

// viewMode tracks which screen is active.
type viewMode int

const (
	viewDashboard viewMode = iota
	viewDetail
)

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

// issueDetailMsg carries the result of fetching issue detail from the API.
type issueDetailMsg struct {
	detail *types.IssueDetail
	err    error
}

// sseClosedMsg signals the SSE subscription ended (404 or terminal error).
type sseClosedMsg struct{}

// pollTickMsg triggers a periodic state poll.
type pollTickMsg struct{}

// tickMsg triggers countdown updates.
type tickMsg time.Time

// Model is the Bubble Tea model for the Symphony TUI dashboard.
type Model struct {
	client      *client.Client
	width       int
	height      int
	cursor      int
	stateAt     time.Time
	prompt      promptMode
	view          viewMode
	detailAgentID string      // ID of the agent shown in detail view
	detailExtra   types.Agent // preserved issue detail fields from API fetch
	statusText    string      // transient status message (errors, etc.)
	metrics     types.AgentMetrics
	limits      []types.RateLimit
	project     types.ProjectInfo
	agents      []types.Agent

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

	case issueDetailMsg:
		if msg.err == nil && msg.detail != nil && m.detailAgentID != "" {
			d := msg.detail
			if d.Title != nil && *d.Title != "" {
				m.detailExtra.Title = *d.Title
			}
			if d.Description != nil && *d.Description != "" {
				m.detailExtra.Description = *d.Description
			}
			if d.URL != nil && *d.URL != "" {
				m.detailExtra.URL = *d.URL
			}
			if len(d.Labels) > 0 {
				m.detailExtra.Labels = d.Labels
			}
		}
		return m, nil

	case tmuxResultMsg:
		if msg.err != nil {
			m.statusText = msg.err.Error()
		} else {
			m.statusText = ""
		}
		return m, nil
	}
	return m, nil
}

// View renders the dashboard.
func (m Model) View() string {
	if m.view == viewDetail && m.detailAgentID != "" {
		if a, ok := m.findDetailAgent(); ok {
			return view.RenderDetailView(a, m.width, m.height, m.statusText)
		}
	}
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

// findDetailAgent looks up the detail agent by ID in the current agents slice
// and merges any preserved issue detail fields from the API fetch.
func (m Model) findDetailAgent() (types.Agent, bool) {
	for _, a := range m.agents {
		if a.ID == m.detailAgentID {
			if a.Title == "" && m.detailExtra.Title != "" {
				a.Title = m.detailExtra.Title
			}
			if a.Description == "" && m.detailExtra.Description != "" {
				a.Description = m.detailExtra.Description
			}
			if a.URL == "" && m.detailExtra.URL != "" {
				a.URL = m.detailExtra.URL
			}
			if len(a.Labels) == 0 && len(m.detailExtra.Labels) > 0 {
				a.Labels = m.detailExtra.Labels
			}
			return a, true
		}
	}
	return types.Agent{}, false
}
