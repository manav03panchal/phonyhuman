package model

import (
	"context"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/humancorp/symphony/tui/client"
	"github.com/humancorp/symphony/tui/types"
	"github.com/humancorp/symphony/tui/view"
)

const pollInterval = 2 * time.Second

// healthMsg carries the result of a health check.
type healthMsg struct {
	resp types.Health
	err  error
}

// stateMsg carries the result of a state fetch (SSE or poll).
type stateMsg struct {
	state *types.State
	err   error
}

// sseClosedMsg signals the SSE subscription ended (404 or terminal error).
type sseClosedMsg struct{}

// pollTickMsg triggers a periodic state poll.
type pollTickMsg struct{}

// Model is the Bubble Tea model for the Symphony TUI.
type Model struct {
	client       *client.Client
	spinner      spinner.Model
	loading      bool
	healthStatus string
	healthErr    error
	state        *types.State
	stateErr     error
	useSSE       bool
	sseSub       *client.SSESubscription
}

// New creates a Model wired to the given API client.
// It eagerly creates an SSE subscription so the pointer is shared across
// Bubble Tea's value copies of the model.
func New(c *client.Client) Model {
	s := spinner.New()
	s.Spinner = spinner.Dot
	s.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("212"))
	return Model{
		client:  c,
		spinner: s,
		loading: true,
		useSSE:  true,
		sseSub:  c.SubscribeSSE(context.Background()),
	}
}

// Init starts the spinner, fires the health check, and begins listening for SSE events.
func (m Model) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, m.checkHealth(), waitForSSE(m.sseSub))
}

// Update handles messages.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			if m.sseSub != nil {
				m.sseSub.Close()
			}
			return m, tea.Quit
		}

	case healthMsg:
		m.loading = false
		if msg.err != nil {
			m.healthErr = msg.err
		} else {
			m.healthStatus = msg.resp.Status
		}
		return m, nil

	case stateMsg:
		if msg.err != nil {
			m.stateErr = msg.err
		} else {
			m.state = msg.state
			m.stateErr = nil
		}
		if m.useSSE && m.sseSub != nil {
			return m, waitForSSE(m.sseSub)
		}
		return m, nil

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

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd
	}

	return m, nil
}

// View renders the current state.
func (m Model) View() string {
	return view.Render(m.client.BaseURL(), m.loading, m.healthStatus, m.healthErr, m.spinner.View())
}

// checkHealth returns a Cmd that performs the health check.
func (m Model) checkHealth() tea.Cmd {
	return func() tea.Msg {
		resp, err := m.client.FetchHealth(context.Background())
		if err != nil {
			return healthMsg{err: err}
		}
		return healthMsg{resp: *resp}
	}
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

// pollState fetches state via HTTP GET.
func (m Model) pollState() tea.Cmd {
	return func() tea.Msg {
		state, err := m.client.FetchState(context.Background())
		return stateMsg{state: state, err: err}
	}
}

// schedulePoll returns a Cmd that sends a pollTickMsg after the poll interval.
func schedulePoll() tea.Cmd {
	return tea.Tick(pollInterval, func(time.Time) tea.Msg {
		return pollTickMsg{}
	})
}
