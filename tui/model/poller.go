package model

import (
	"context"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/humancorp/symphony/tui/client"
	"github.com/humancorp/symphony/tui/types"
)

const pollInterval = 2 * time.Second

// pollTimeout is the per-request timeout for HTTP state polls.
const pollTimeout = 10 * time.Second

// waitForSSE returns a Cmd that blocks until the next SSE event arrives.
// It selects on both the events channel and the subscription's Done channel
// to detect shutdown without relying on the events channel being closed.
func waitForSSE(sub *client.SSESubscription) tea.Cmd {
	return func() tea.Msg {
		select {
		case event, ok := <-sub.Events():
			if !ok {
				return sseClosedMsg{}
			}
			state, err := client.ParseStateEvent(event.Data)
			return stateMsg{state: state, err: err}
		case <-sub.Done():
			return sseClosedMsg{}
		}
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

func (m Model) fetchIssueDetail(identifier string) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(m.ctx, 5*time.Second)
		defer cancel()
		detail, err := m.client.FetchIssueDetail(ctx, identifier)
		return issueDetailMsg{detail: detail, err: err}
	}
}

func tickCmd() tea.Cmd {
	return tea.Tick(pollInterval, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
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
				Used:  max(0, rl.PrimaryBucket.Capacity-rl.PrimaryBucket.Remaining),
				Limit: rl.PrimaryBucket.Capacity,
			})
		}
		if rl.SecondaryBucket != nil {
			m.limits = append(m.limits, types.RateLimit{
				Name:  "Secondary",
				Used:  max(0, rl.SecondaryBucket.Capacity-rl.SecondaryBucket.Remaining),
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

		title := ""
		if e.Title != nil {
			title = *e.Title
		}
		desc := ""
		if e.Description != nil {
			desc = *e.Description
		}
		agentURL := ""
		if e.URL != nil {
			agentURL = *e.URL
		}

		m.agents = append(m.agents, types.Agent{
			ID:              e.IssueIdentifier,
			Title:           title,
			Description:     desc,
			URL:             agentURL,
			Labels:          e.Labels,
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
			CommitsCount:    e.CommitsCount,
			PRsCount:        e.PRsCount,
		})
	}
	m.metrics.AgentTimeSeconds = totalAgentSec

	// Clamp cursor after agent list changes
	if m.cursor >= len(m.agents) && len(m.agents) > 0 {
		m.cursor = len(m.agents) - 1
	}

	// Exit detail view if the agent is no longer in the list
	if m.detailAgentID != "" {
		found := false
		for i := range m.agents {
			if m.agents[i].ID == m.detailAgentID {
				found = true
				break
			}
		}
		if !found {
			m.detailAgentID = ""
			m.detailExtra = types.Agent{}
			m.view = viewDashboard
		}
	}
}
