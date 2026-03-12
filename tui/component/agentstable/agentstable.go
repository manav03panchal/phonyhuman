// Package agentstable provides an interactive Bubble Tea table component for
// displaying orchestrated agent state. It uses charmbracelet/bubbles/table for
// keyboard-navigable, scrollable rows with colored status indicators.
package agentstable

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/table"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/humancorp/symphony/tui/humanize"
	"github.com/humancorp/symphony/tui/types"
)

// Default column widths.
const (
	colWidthID      = 18
	colWidthStage   = 10
	colWidthAgeTurn = 10
	colWidthIn      = 10
	colWidthOut     = 10
	colWidthCost    = 9
	colWidthSession = 14
	colWidthEvent   = 30
)

var (
	emptyStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241")).
			Italic(true)
)

// Model is the Bubble Tea model for the agents table.
type Model struct {
	table  table.Model
	agents []types.Agent
	width  int
	height int
	ready  bool
}

// New creates a new agents table with default configuration.
func New() Model {
	cols := columns()
	t := table.New(
		table.WithColumns(cols),
		table.WithRows([]table.Row{}),
		table.WithFocused(true),
		table.WithHeight(10),
	)

	s := table.DefaultStyles()
	s.Header = s.Header.
		BorderStyle(lipgloss.NormalBorder()).
		BorderForeground(lipgloss.Color("240")).
		BorderBottom(true).
		Bold(true)
	s.Selected = s.Selected.
		Foreground(lipgloss.Color("229")).
		Background(lipgloss.Color("57")).
		Bold(false)
	t.SetStyles(s)

	return Model{
		table: t,
	}
}

// Init satisfies tea.Model.
func (m Model) Init() tea.Cmd {
	return nil
}

// Update handles messages for the agents table.
func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	switch msg := msg.(type) {
	case types.AgentsUpdatedMsg:
		m.agents = msg.Agents
		m.table.SetRows(buildRows(m.agents))
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "enter":
			if len(m.agents) > 0 {
				idx := m.table.Cursor()
				sorted := sortedAgents(m.agents)
				if idx >= 0 && idx < len(sorted) {
					return m, emitAgentSelected(sorted[idx])
				}
			}
			return m, nil
		}
	}

	var cmd tea.Cmd
	m.table, cmd = m.table.Update(msg)
	return m, cmd
}

// View renders the agents table or empty state.
func (m Model) View() string {
	if len(m.agents) == 0 {
		return renderEmpty(m.width, m.height)
	}
	return m.table.View()
}

// SetSize updates the table dimensions.
func (m *Model) SetSize(width, height int) {
	m.width = width
	m.height = height
	if height > 2 {
		m.table.SetHeight(height - 2) // leave room for header/border
	}
	m.ready = true
}

// Focused returns whether the table has focus.
func (m Model) Focused() bool {
	return m.table.Focused()
}

// Focus gives focus to the table.
func (m *Model) Focus() {
	m.table.Focus()
}

// Blur removes focus from the table.
func (m *Model) Blur() {
	m.table.Blur()
}

// --- internal ---

func columns() []table.Column {
	return []table.Column{
		{Title: "ID", Width: colWidthID},
		{Title: "State", Width: colWidthStage},
		{Title: "Age/Turn", Width: colWidthAgeTurn},
		{Title: "In", Width: colWidthIn},
		{Title: "Out", Width: colWidthOut},
		{Title: "Cost", Width: colWidthCost},
		{Title: "Session", Width: colWidthSession},
		{Title: "Last Event", Width: colWidthEvent},
	}
}

func buildRows(agents []types.Agent) []table.Row {
	sorted := sortedAgents(agents)
	rows := make([]table.Row, len(sorted))
	for i, a := range sorted {
		rows[i] = agentRow(a)
	}
	return rows
}

func sortedAgents(agents []types.Agent) []types.Agent {
	sorted := make([]types.Agent, len(agents))
	copy(sorted, agents)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].ID < sorted[j].ID
	})
	return sorted
}

func agentRow(a types.Agent) table.Row {
	dot := statusDot(a.Status)
	age := formatAge(a.StartedAt)
	ageTurn := fmt.Sprintf("%s/T%d", age, a.Turn)
	session := truncateStr(a.SessionID, colWidthSession)
	event := humanize.AgentMessage(a.LastEvent)

	return table.Row{
		dot + " " + truncateStr(a.ID, colWidthID-3),
		a.Stage,
		ageTurn,
		formatTokens(a.InputTokens),
		formatTokens(a.OutputTokens),
		formatCost(a.CostUSD),
		session,
		event,
	}
}

func formatCost(cost float64) string {
	if cost == 0 {
		return "—"
	}
	if cost < 0.01 {
		return "<$0.01"
	}
	return fmt.Sprintf("$%.2f", cost)
}

func statusDot(status types.AgentStatus) string {
	color := status.StatusColor()
	style := lipgloss.NewStyle().Foreground(lipgloss.Color(color))
	return style.Render("●")
}

func formatAge(started time.Time) string {
	if started.IsZero() {
		return "—"
	}
	d := time.Since(started).Truncate(time.Second)
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		return fmt.Sprintf("%dm%ds", int(d.Minutes()), int(d.Seconds())%60)
	}
	return fmt.Sprintf("%dh%dm", int(d.Hours()), int(d.Minutes())%60)
}

func formatTokens(tokens int) string {
	if tokens == 0 {
		return "—"
	}
	if tokens >= 1_000_000 {
		return fmt.Sprintf("%.1fM", float64(tokens)/1_000_000)
	}
	if tokens >= 1_000 {
		return fmt.Sprintf("%.1fk", float64(tokens)/1_000)
	}
	return fmt.Sprintf("%d", tokens)
}

func truncateStr(s string, max int) string {
	runes := []rune(s)
	if len(runes) > max {
		if max > 3 {
			return string(runes[:max-3]) + "..."
		}
		return string(runes[:max])
	}
	return s
}

func renderEmpty(width, height int) string {
	msg := emptyStyle.Render("No active agents")
	if width == 0 {
		return "\n" + msg + "\n"
	}

	// Center horizontally
	pad := (width - lipgloss.Width(msg)) / 2
	if pad < 0 {
		pad = 0
	}

	var b strings.Builder
	// Center vertically
	topPad := height / 3
	if topPad < 1 {
		topPad = 1
	}
	for i := 0; i < topPad; i++ {
		b.WriteByte('\n')
	}
	b.WriteString(strings.Repeat(" ", pad))
	b.WriteString(msg)
	b.WriteByte('\n')
	return b.String()
}

func emitAgentSelected(a types.Agent) tea.Cmd {
	return func() tea.Msg {
		return types.AgentSelectedMsg{Agent: a}
	}
}
