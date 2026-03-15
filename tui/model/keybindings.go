package model

import (
	tea "github.com/charmbracelet/bubbletea"

	"github.com/humancorp/symphony/tui/types"
)

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()

	// Detail view keys — handle first.
	if m.view == viewDetail {
		switch key {
		case "esc", "backspace":
			m.view = viewDashboard
			m.detailAgentID = ""
			m.detailExtra = types.Agent{}
			m.statusText = ""
		case "a":
			if a, ok := m.findDetailAgent(); ok {
				m.statusText = ""
				return m, openAgentTmux(a)
			}
		case "q", "ctrl+c":
			m.prompt = promptConfirmQuit
			m.view = viewDashboard
			m.detailAgentID = ""
			m.detailExtra = types.Agent{}
			m.statusText = ""
		}
		return m, nil
	}

	// Handle confirmation prompts.
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
			m.detailAgentID = m.agents[m.cursor].ID
			m.detailExtra = types.Agent{}
			m.view = viewDetail
			m.statusText = ""
			return m, m.fetchIssueDetail(m.detailAgentID)
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
