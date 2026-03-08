package model

import (
	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/humancorp/symphony/tui/client"
	"github.com/humancorp/symphony/tui/types"
	"github.com/humancorp/symphony/tui/view"
)

// healthMsg carries the result of a health check.
type healthMsg struct {
	resp types.HealthResponse
	err  error
}

// Model is the Bubble Tea model for the Symphony TUI.
type Model struct {
	client       *client.Client
	spinner      spinner.Model
	loading      bool
	healthStatus string
	healthErr    error
}

// New creates a Model wired to the given API client.
func New(c *client.Client) Model {
	s := spinner.New()
	s.Spinner = spinner.Dot
	s.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("212"))
	return Model{
		client:  c,
		spinner: s,
		loading: true,
	}
}

// Init starts the spinner and fires the health check command.
func (m Model) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, m.checkHealth())
}

// Update handles messages.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
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

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd
	}

	return m, nil
}

// View renders the current state.
func (m Model) View() string {
	return view.Render(m.client.BaseURL, m.loading, m.healthStatus, m.healthErr, m.spinner.View())
}

// checkHealth returns a Cmd that performs the health check.
func (m Model) checkHealth() tea.Cmd {
	return func() tea.Msg {
		resp, err := m.client.CheckHealth()
		return healthMsg{resp: resp, err: err}
	}
}
