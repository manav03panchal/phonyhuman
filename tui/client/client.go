// Package client provides a typed HTTP client for the Symphony Phoenix API.
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	"github.com/humancorp/symphony/tui/types"
)

const (
	defaultTimeout = 5 * time.Second
	maxRetries     = 3
	retryBaseDelay = 500 * time.Millisecond
	statePath      = "/api/v1/state"
	healthPath     = "/health"
	fleetPausePath = "/api/v1/fleet/pause"
	fleetResumePath = "/api/v1/fleet/resume"
)

// Client fetches orchestrator state from the Symphony Phoenix API.
type Client struct {
	baseURL      string
	httpClient   *http.Client
	pollInterval time.Duration
}

// Option configures a Client.
type Option func(*Client)

// WithTimeout sets the HTTP client timeout. Default is 5s.
func WithTimeout(d time.Duration) Option {
	return func(c *Client) {
		c.httpClient.Timeout = d
	}
}

// WithPollInterval sets the default polling interval for Poll.
func WithPollInterval(d time.Duration) Option {
	return func(c *Client) {
		c.pollInterval = d
	}
}

// WithHTTPClient replaces the underlying http.Client.
func WithHTTPClient(hc *http.Client) Option {
	return func(c *Client) {
		c.httpClient = hc
	}
}

// New creates a Client for the given base URL.
func New(baseURL string, opts ...Option) (*Client, error) {
	u, err := url.Parse(baseURL)
	if err != nil {
		return nil, fmt.Errorf("invalid base URL: %w", err)
	}
	if u.Scheme == "" || u.Host == "" {
		return nil, fmt.Errorf("base URL must include scheme and host: %s", baseURL)
	}

	c := &Client{
		baseURL:      baseURL,
		httpClient:   &http.Client{Timeout: defaultTimeout},
		pollInterval: 2 * time.Second,
	}
	for _, o := range opts {
		o(c)
	}
	return c, nil
}

// BaseURL returns the configured base URL.
func (c *Client) BaseURL() string {
	return c.baseURL
}

// FetchState calls GET /api/v1/state and returns the deserialized orchestrator state.
func (c *Client) FetchState(ctx context.Context) (*types.State, error) {
	body, err := c.getWithRetry(ctx, statePath)
	if err != nil {
		return nil, fmt.Errorf("fetch state: %w", err)
	}

	var state types.State
	if err := json.Unmarshal(body, &state); err != nil {
		return nil, fmt.Errorf("decode state: %w", err)
	}
	return &state, nil
}

// FetchHealth calls GET /health and returns the deserialized health status.
func (c *Client) FetchHealth(ctx context.Context) (*types.Health, error) {
	body, err := c.getWithRetry(ctx, healthPath)
	if err != nil {
		return nil, fmt.Errorf("fetch health: %w", err)
	}

	var health types.Health
	if err := json.Unmarshal(body, &health); err != nil {
		return nil, fmt.Errorf("decode health: %w", err)
	}
	return &health, nil
}

// Poll sends orchestrator state snapshots on the provided channel at the given
// interval. It blocks until the context is cancelled. The channel is not closed
// by Poll; the caller owns the channel lifetime.
func (c *Client) Poll(ctx context.Context, interval time.Duration, ch chan<- *types.State) {
	if interval <= 0 {
		interval = c.pollInterval
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// Send an initial state immediately.
	if state, err := c.FetchState(ctx); err == nil {
		select {
		case ch <- state:
		case <-ctx.Done():
			return
		}
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			state, err := c.FetchState(ctx)
			if err != nil {
				continue // transient errors are silently skipped
			}
			select {
			case ch <- state:
			case <-ctx.Done():
				return
			}
		}
	}
}

// PauseFleet calls POST /api/v1/fleet/pause.
func (c *Client) PauseFleet(ctx context.Context, reason string) error {
	payload, _ := json.Marshal(map[string]string{"reason": reason})
	return c.doPost(ctx, fleetPausePath, payload)
}

// ResumeFleet calls POST /api/v1/fleet/resume.
func (c *Client) ResumeFleet(ctx context.Context) error {
	return c.doPost(ctx, fleetResumePath, nil)
}

func (c *Client) doPost(ctx context.Context, path string, body []byte) error {
	endpoint := c.baseURL + path
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, reader)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, respBody)
	}
	return nil
}

// getWithRetry performs a GET request with retry on transient errors.
func (c *Client) getWithRetry(ctx context.Context, path string) ([]byte, error) {
	endpoint := c.baseURL + path
	var lastErr error

	for attempt := range maxRetries {
		if attempt > 0 {
			delay := retryBaseDelay * time.Duration(1<<(attempt-1))
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(delay):
			}
		}

		body, err := c.doGet(ctx, endpoint)
		if err == nil {
			return body, nil
		}

		if !isTransient(err) {
			return nil, err
		}
		lastErr = err
	}
	return nil, fmt.Errorf("max retries exceeded: %w", lastErr)
}

func (c *Client) doGet(ctx context.Context, endpoint string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, &TransientError{Err: err}
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, &TransientError{Err: fmt.Errorf("read body: %w", err)}
	}

	if resp.StatusCode >= 500 {
		return nil, &TransientError{
			Err: fmt.Errorf("server error: HTTP %d", resp.StatusCode),
		}
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("client error: HTTP %d: %s", resp.StatusCode, body)
	}

	return body, nil
}

// TransientError wraps errors that should be retried.
type TransientError struct {
	Err error
}

func (e *TransientError) Error() string { return e.Err.Error() }
func (e *TransientError) Unwrap() error { return e.Err }

func isTransient(err error) bool {
	_, ok := err.(*TransientError)
	return ok
}

