package client

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/humancorp/symphony/tui/types"
)

// Client is an HTTP client for the Symphony API.
type Client struct {
	BaseURL    string
	httpClient *http.Client
}

// New creates a Client with the given base URL.
func New(baseURL string) *Client {
	return &Client{
		BaseURL: baseURL,
		httpClient: &http.Client{
			Timeout: 5 * time.Second,
		},
	}
}

// CheckHealth calls GET /health and returns the parsed response.
func (c *Client) CheckHealth() (types.HealthResponse, error) {
	resp, err := c.httpClient.Get(c.BaseURL + "/health")
	if err != nil {
		return types.HealthResponse{}, fmt.Errorf("health check failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return types.HealthResponse{}, fmt.Errorf("health check returned status %d", resp.StatusCode)
	}

	var health types.HealthResponse
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		return types.HealthResponse{}, fmt.Errorf("failed to decode health response: %w", err)
	}

	return health, nil
}
