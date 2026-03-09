// Package types defines the Go structs that mirror the Symphony Phoenix API
// JSON responses for orchestrator state and health endpoints.
package types

// State represents the full orchestrator snapshot returned by GET /api/v1/state.
type State struct {
	GeneratedAt      string       `json:"generated_at"`
	Counts           Counts       `json:"counts"`
	Running          []AgentEntry `json:"running"`
	Retrying         []RetryEntry `json:"retrying"`
	AgentTotals      AgentTotals  `json:"agent_totals"`
	RateLimits       RateLimits   `json:"rate_limits"`
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
	IssueID           string  `json:"issue_id"`
	IssueIdentifier   string  `json:"issue_identifier"`
	State             string  `json:"state"`
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
	PrimaryBucket   *Bucket `json:"primary_bucket"`
	SecondaryBucket *Bucket `json:"secondary_bucket"`
	Credits         float64 `json:"credits"`
}

// Bucket represents a rate limit bucket with capacity and remaining values.
type Bucket struct {
	Capacity  int `json:"capacity"`
	Remaining int `json:"remaining"`
}

// Health represents the response from GET /health.
type Health struct {
	Status        string `json:"status"`
	UptimeSeconds int    `json:"uptime_seconds"`
	ActiveAgents  int    `json:"active_agents"`
}

// HealthResponse represents the response from the /health endpoint.
// Alias for backward compatibility with the TUI scaffold.
type HealthResponse = Health
