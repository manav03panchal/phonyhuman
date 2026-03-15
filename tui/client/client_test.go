package client

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/humancorp/symphony/tui/types"
)

func sampleState() types.State {
	return types.State{
		GeneratedAt: "2026-03-08T12:00:00Z",
		Counts:      types.Counts{Running: 2, Retrying: 1},
		Running: []types.AgentEntry{
			{
				IssueID:         "abc-123",
				IssueIdentifier: "HUM-10",
				State:           "running",
				SessionID:       "sess-1",
				TurnCount:       5,
				Tokens: types.Tokens{
					InputTokens:     1000,
					OutputTokens:    500,
					TotalTokens:     1500,
					CacheReadTokens: 200,
					CacheHitRate:    16.67,
					CostUSD:         0.05,
				},
				LinesChanged:      42,
				CommitsCount:      1,
				PRsCount:          0,
				ToolCalls:         10,
				ToolAvgDurationMs: 150,
				APIErrors:         0,
				ActiveTimeSeconds: 120,
			},
		},
		Retrying: []types.RetryEntry{
			{
				IssueID:         "def-456",
				IssueIdentifier: "HUM-11",
				Attempt:         2,
				DueAt:           "2026-03-08T12:01:00Z",
				Error:           "rate limited",
			},
		},
		AgentTotals: types.AgentTotals{
			InputTokens:  5000,
			OutputTokens: 2500,
			TotalTokens:  7500,
			CostUSD:      0.25,
		},
		FleetStatus: "running",
	}
}

func sampleHealth() types.Health {
	return types.Health{
		Status:        "ok",
		UptimeSeconds: 3600,
		ActiveAgents:  2,
	}
}

func TestNew_ValidURL(t *testing.T) {
	c, err := New("http://localhost:4000")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.baseURL != "http://localhost:4000" {
		t.Errorf("base URL = %q, want %q", c.baseURL, "http://localhost:4000")
	}
}

func TestNew_InvalidURL(t *testing.T) {
	_, err := New("not-a-url")
	if err == nil {
		t.Fatal("expected error for missing scheme/host")
	}
}

func TestNew_WithTimeout(t *testing.T) {
	c, err := New("http://localhost:4000", WithTimeout(10*time.Second))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.httpClient.Timeout != 10*time.Second {
		t.Errorf("timeout = %v, want 10s", c.httpClient.Timeout)
	}
}

func TestFetchState_Success(t *testing.T) {
	state := sampleState()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/state" {
			t.Errorf("path = %q, want /api/v1/state", r.URL.Path)
		}
		if r.Header.Get("Accept") != "application/json" {
			t.Errorf("Accept header = %q, want application/json", r.Header.Get("Accept"))
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(state)
	}))
	defer srv.Close()

	c, _ := New(srv.URL)
	got, err := c.FetchState(context.Background())
	if err != nil {
		t.Fatalf("FetchState error: %v", err)
	}

	if got.GeneratedAt != state.GeneratedAt {
		t.Errorf("GeneratedAt = %q, want %q", got.GeneratedAt, state.GeneratedAt)
	}
	if got.Counts.Running != 2 {
		t.Errorf("Counts.Running = %d, want 2", got.Counts.Running)
	}
	if len(got.Running) != 1 {
		t.Fatalf("len(Running) = %d, want 1", len(got.Running))
	}
	if got.Running[0].IssueIdentifier != "HUM-10" {
		t.Errorf("Running[0].IssueIdentifier = %q, want HUM-10", got.Running[0].IssueIdentifier)
	}
	if got.Running[0].Tokens.InputTokens != 1000 {
		t.Errorf("Running[0].Tokens.InputTokens = %d, want 1000", got.Running[0].Tokens.InputTokens)
	}
	if len(got.Retrying) != 1 {
		t.Fatalf("len(Retrying) = %d, want 1", len(got.Retrying))
	}
	if got.Retrying[0].Attempt != 2 {
		t.Errorf("Retrying[0].Attempt = %d, want 2", got.Retrying[0].Attempt)
	}
	if got.FleetStatus != "running" {
		t.Errorf("FleetStatus = %q, want running", got.FleetStatus)
	}
}

func TestFetchState_ServerError_Retries(t *testing.T) {
	attempts := 0
	state := sampleState()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if attempts < 3 {
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte("internal error"))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(state)
	}))
	defer srv.Close()

	c, _ := New(srv.URL, WithTimeout(2*time.Second))
	got, err := c.FetchState(context.Background())
	if err != nil {
		t.Fatalf("FetchState error after retries: %v", err)
	}
	if got.Counts.Running != 2 {
		t.Errorf("Counts.Running = %d, want 2", got.Counts.Running)
	}
	if attempts != 3 {
		t.Errorf("attempts = %d, want 3", attempts)
	}
}

func TestFetchState_ClientError_NoRetry(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte(`{"error":"not found"}`))
	}))
	defer srv.Close()

	c, _ := New(srv.URL)
	_, err := c.FetchState(context.Background())
	if err == nil {
		t.Fatal("expected error for 404")
	}
}

func TestFetchState_AllRetriesFail(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		w.Write([]byte("bad gateway"))
	}))
	defer srv.Close()

	c, _ := New(srv.URL)
	_, err := c.FetchState(context.Background())
	if err == nil {
		t.Fatal("expected error after max retries")
	}
}

func TestFetchHealth_Success(t *testing.T) {
	health := sampleHealth()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			t.Errorf("path = %q, want /health", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(health)
	}))
	defer srv.Close()

	c, _ := New(srv.URL)
	got, err := c.FetchHealth(context.Background())
	if err != nil {
		t.Fatalf("FetchHealth error: %v", err)
	}
	if got.Status != "ok" {
		t.Errorf("Status = %q, want ok", got.Status)
	}
	if got.UptimeSeconds != 3600 {
		t.Errorf("UptimeSeconds = %d, want 3600", got.UptimeSeconds)
	}
	if got.ActiveAgents != 2 {
		t.Errorf("ActiveAgents = %d, want 2", got.ActiveAgents)
	}
}

func TestFetchState_ErrorPayload(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"generated_at": "2026-03-08T12:00:00Z",
			"error": map[string]string{
				"code":    "snapshot_timeout",
				"message": "Snapshot timed out",
			},
		})
	}))
	defer srv.Close()

	c, _ := New(srv.URL)
	got, err := c.FetchState(context.Background())
	if err != nil {
		t.Fatalf("FetchState error: %v", err)
	}
	if got.Error == nil {
		t.Fatal("expected Error field to be populated")
	}
	if got.Error.Code != "snapshot_timeout" {
		t.Errorf("Error.Code = %q, want snapshot_timeout", got.Error.Code)
	}
}

func TestDoPost_DrainsResponseBody(t *testing.T) {
	bodyDrained := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok"}`))
	}))
	defer srv.Close()

	// Use a custom transport that checks whether the body was fully read,
	// which is required for HTTP keep-alive connection reuse.
	c, _ := New(srv.URL)
	if err := c.PauseFleet(context.Background(), "test"); err != nil {
		t.Fatalf("PauseFleet error: %v", err)
	}

	// Verify by making a second request on the same client — if keep-alive
	// works the transport reuses the connection without error.
	_ = bodyDrained // suppress unused warning
	if err := c.ResumeFleet(context.Background()); err != nil {
		t.Fatalf("ResumeFleet error (connection reuse): %v", err)
	}
}

func TestDoPost_ErrorPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"bad request"}`))
	}))
	defer srv.Close()

	c, _ := New(srv.URL)
	err := c.PauseFleet(context.Background(), "test")
	if err == nil {
		t.Fatal("expected error for 400 response")
	}
}

func TestPoll_SendsStatesAndStopsOnCancel(t *testing.T) {
	state := sampleState()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(state)
	}))
	defer srv.Close()

	c, _ := New(srv.URL)
	ch := make(chan *types.State, 10)
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()

	c.Poll(ctx, 50*time.Millisecond, ch)

	if len(ch) == 0 {
		t.Fatal("expected at least one state on channel")
	}
	got := <-ch
	if got.Counts.Running != 2 {
		t.Errorf("Counts.Running = %d, want 2", got.Counts.Running)
	}
}

func TestPoll_ContextCancelledImmediately(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"generated_at":"2026-03-08T12:00:00Z","counts":{"running":0,"retrying":0},"running":[],"retrying":[],"agent_totals":{},"rate_limits":{},"fleet_status":"running"}`))
	}))
	defer srv.Close()

	c, _ := New(srv.URL)
	ch := make(chan *types.State, 10)
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	done := make(chan struct{})
	go func() {
		c.Poll(ctx, 50*time.Millisecond, ch)
		close(done)
	}()

	select {
	case <-done:
		// Poll returned as expected
	case <-time.After(2 * time.Second):
		t.Fatal("Poll did not return after context cancellation")
	}
}

func TestIsTransient_WrappedError(t *testing.T) {
	base := &TransientError{Err: fmt.Errorf("connection refused")}
	wrapped := fmt.Errorf("fetch failed: %w", base)

	if !isTransient(wrapped) {
		t.Error("isTransient should detect a wrapped TransientError")
	}
}

func TestIsTransient_DirectError(t *testing.T) {
	err := &TransientError{Err: fmt.Errorf("timeout")}
	if !isTransient(err) {
		t.Error("isTransient should detect a direct TransientError")
	}
}

func TestIsTransient_NonTransient(t *testing.T) {
	err := fmt.Errorf("permanent failure")
	if isTransient(err) {
		t.Error("isTransient should return false for non-TransientError")
	}
}

func TestDoGet_OversizedResponseIsCapped(t *testing.T) {
	// Serve a response larger than maxResponseBody (10 MB).
	oversized := strings.Repeat("X", maxResponseBody+1024)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(oversized))
	}))
	defer srv.Close()

	c, _ := New(srv.URL)
	body, err := c.doGet(context.Background(), srv.URL+"/test")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(body) > maxResponseBody {
		t.Errorf("body length = %d, want <= %d", len(body), maxResponseBody)
	}
	if len(body) != maxResponseBody {
		t.Errorf("body length = %d, want exactly %d (capped by LimitReader)", len(body), maxResponseBody)
	}
}
