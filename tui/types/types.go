package types

// HealthResponse represents the response from the /health endpoint.
type HealthResponse struct {
	Status string `json:"status"`
}

// AgentMetrics holds per-agent or aggregated agent metrics.
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

	RuntimeSeconds int
	TPS            float64
	TPSHistory     []float64 // sparkline data points

	LinesChanged int
	Commits      int
	PRs          int

	ToolCalls         int
	ToolAvgDurationMs int
	ToolErrors        int
}

// RateLimit represents a single API rate limit gauge.
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
