// Package types defines the Go structs that mirror the Symphony Phoenix API
// JSON responses for orchestrator state and health endpoints.
package types

import (
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// State represents the full orchestrator snapshot returned by GET /api/v1/state.
type State struct {
	GeneratedAt      string       `json:"generated_at"`
	Counts           Counts       `json:"counts"`
	Running          []AgentEntry `json:"running"`
	Retrying         []RetryEntry `json:"retrying"`
	AgentTotals      AgentTotals  `json:"agent_totals"`
	RateLimits       *RateLimits  `json:"rate_limits"`
	MaxAgents        int          `json:"max_agents"`
	FleetStatus      string       `json:"fleet_status"`
	FleetPausedUntil *string      `json:"fleet_paused_until"`
	FleetPauseReason *string      `json:"fleet_pause_reason"`
	Error            *StateError  `json:"error,omitempty"`
}

// StateError is returned when the orchestrator snapshot is unavailable or timed out.
type StateError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Counts holds running/retrying agent counts.
type Counts struct {
	Running  int `json:"running"`
	Retrying int `json:"retrying"`
}

// Tokens holds token usage metrics for an agent session.
type Tokens struct {
	InputTokens     int     `json:"input_tokens"`
	OutputTokens    int     `json:"output_tokens"`
	TotalTokens     int     `json:"total_tokens"`
	CacheReadTokens int     `json:"cache_read_tokens"`
	CacheHitRate    float64 `json:"cache_hit_rate"`
	CostUSD         float64 `json:"cost_usd"`
}

// AgentEntry represents a currently running agent in the orchestrator.
type AgentEntry struct {
	IssueID           string   `json:"issue_id"`
	IssueIdentifier   string   `json:"issue_identifier"`
	Title             *string  `json:"title"`
	Description       *string  `json:"description"`
	URL               *string  `json:"url"`
	Labels            []string `json:"labels"`
	State             string   `json:"state"`
	SessionID         string  `json:"session_id"`
	TurnCount         int     `json:"turn_count"`
	LastEvent         *string `json:"last_event"`
	LastMessage       *string `json:"last_message"`
	StartedAt         *string `json:"started_at"`
	LastEventAt       *string `json:"last_event_at"`
	Model             *string `json:"model"`
	Tokens            Tokens  `json:"tokens"`
	LinesChanged      int     `json:"lines_changed"`
	CommitsCount      int     `json:"commits_count"`
	PRsCount          int     `json:"prs_count"`
	ToolCalls         int     `json:"tool_calls"`
	ToolAvgDurationMs int     `json:"tool_avg_duration_ms"`
	APIErrors         int     `json:"api_errors"`
	ActiveTimeSeconds int     `json:"active_time_seconds"`
}

// RetryEntry represents an agent waiting to be retried.
type RetryEntry struct {
	IssueID         string `json:"issue_id"`
	IssueIdentifier string `json:"issue_identifier"`
	Attempt         int    `json:"attempt"`
	DueAt           string `json:"due_at"`
	Error           string `json:"error"`
}

// AgentTotals holds aggregate metrics across all agent sessions.
type AgentTotals struct {
	InputTokens         int     `json:"input_tokens"`
	OutputTokens        int     `json:"output_tokens"`
	TotalTokens         int     `json:"total_tokens"`
	CacheReadTokens     int     `json:"cache_read_tokens"`
	CacheCreationTokens int     `json:"cache_creation_tokens"`
	CacheHitRate        float64 `json:"cache_hit_rate"`
	CostUSD             float64 `json:"cost_usd"`
	Model               *string `json:"model"`
	SecondsRunning      int     `json:"seconds_running"`
	LinesChanged        int     `json:"lines_changed"`
	CommitsCount        int     `json:"commits_count"`
	PRsCount            int     `json:"prs_count"`
	ToolCalls           int     `json:"tool_calls"`
	ToolAvgDurationMs   int     `json:"tool_avg_duration_ms"`
	APIErrors           int     `json:"api_errors"`
	ActiveTimeSeconds   int     `json:"active_time_seconds"`
}

// RateLimits holds rate limit bucket information from the orchestrator.
type RateLimits struct {
	LimitID         string  `json:"limit_id"`
	PrimaryBucket   *Bucket `json:"primary"`
	SecondaryBucket *Bucket `json:"secondary"`
	Credits         float64 `json:"credits"`
}

// Bucket represents a rate limit bucket with capacity and remaining values.
type Bucket struct {
	Capacity  int `json:"capacity"`
	Remaining int `json:"remaining"`
}

// IssueDetail represents the response from GET /api/v1/:issue_identifier.
type IssueDetail struct {
	IssueIdentifier string   `json:"issue_identifier"`
	IssueID         string   `json:"issue_id"`
	Title           *string  `json:"title"`
	Description     *string  `json:"description"`
	URL             *string  `json:"url"`
	Labels          []string `json:"labels"`
	Status          string   `json:"status"`
	Workspace       *struct {
		Path string `json:"path"`
	} `json:"workspace"`
	LastError *string `json:"last_error"`
}

// Health represents the response from GET /health.
type Health struct {
	Status        string `json:"status"`
	UptimeSeconds int    `json:"uptime_seconds"`
	ActiveAgents  int    `json:"active_agents"`
}

// --- Dashboard display types ---

// AgentMetrics holds aggregated agent metrics for dashboard display.
type AgentMetrics struct {
	Running     int
	MaxAgents   int
	FleetStatus string // "running", "paused"

	InputTokens     int64
	OutputTokens    int64
	CacheReadTokens int64
	TotalTokens     int64
	CacheHitRate    float64
	CostUSD         float64
	Model           string

	RuntimeSeconds   int       // wall clock since earliest agent
	AgentTimeSeconds int       // sum of all agent elapsed times
	TPS              float64
	TPSHistory       []float64 // sparkline data points

	LinesChanged int
	Commits      int
	PRs          int

	ToolCalls         int
	ToolAvgDurationMs int
	ToolErrors        int
}

// RateLimit represents a single API rate limit gauge for dashboard display.
type RateLimit struct {
	Name       string
	Used       int
	Limit      int
	ResetInSec int
}

// ProjectInfo holds display metadata about the project.
type ProjectInfo struct {
	LinearURL    string
	DashboardURL string
	RefreshSec   int
}

// FleetActionResponse is returned by fleet pause/resume endpoints.
type FleetActionResponse struct {
	Status string `json:"status"`
}

// --- Agents table display types ---

// AgentStatus represents the lifecycle status of an agent for display purposes.
type AgentStatus string

const (
	StatusActive       AgentStatus = "active"
	StatusTokenUpdate  AgentStatus = "token_update"
	StatusTurnComplete AgentStatus = "turn_complete"
	StatusError        AgentStatus = "error"
	StatusDefault      AgentStatus = "default"
)

// StatusColor returns the Lip Gloss color string for the status.
// Colors: green=active, yellow=token_update, magenta=turn_complete, red=error, blue=default.
func (s AgentStatus) StatusColor() string {
	switch s {
	case StatusActive:
		return "42" // green
	case StatusTokenUpdate:
		return "220" // yellow
	case StatusTurnComplete:
		return "212" // magenta
	case StatusError:
		return "196" // red
	default:
		return "69" // blue
	}
}

// Agent is a display-oriented view model for the agents table component.
// It is converted from AgentEntry by the table adapter layer.
type Agent struct {
	ID              string      `json:"id"`
	Title           string      `json:"title"`
	Description     string      `json:"description"`
	URL             string      `json:"url"`
	Labels          []string    `json:"labels"`
	Stage           string      `json:"stage"`
	StartedAt       time.Time   `json:"started_at"`
	InputTokens     int         `json:"input_tokens"`
	OutputTokens    int         `json:"output_tokens"`
	CacheReadTokens int         `json:"cache_read_tokens"`
	CostUSD         float64     `json:"cost_usd"`
	Model           string      `json:"model"`
	SessionID       string      `json:"session_id"`
	Status          AgentStatus `json:"status"`
	LastEventStr    string      `json:"last_event_str"`
	ToolCalls       int         `json:"tool_calls"`
	LinesChanged    int         `json:"lines_changed"`
}

// AgentsUpdatedMsg is a Bubble Tea message carrying fresh agent state.
type AgentsUpdatedMsg struct {
	Agents []Agent
}

// AgentSelectedMsg is emitted when the user presses Enter on a table row.
type AgentSelectedMsg struct {
	Agent Agent
}

// Ensure messages satisfy tea.Msg (they do implicitly, but this documents intent).
var (
	_ tea.Msg = AgentsUpdatedMsg{}
	_ tea.Msg = AgentSelectedMsg{}
)
