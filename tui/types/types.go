package types

// HealthResponse represents the response from the /health endpoint.
type HealthResponse struct {
	Status string `json:"status"`
}
