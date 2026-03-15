package client

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func newTestClient(t *testing.T, baseURL string) *Client {
	t.Helper()
	c, err := New(baseURL)
	if err != nil {
		t.Fatalf("failed to create client: %v", err)
	}
	return c
}

func TestSubscribeSSE_ReceivesStateUpdate(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/events" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(200)

		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Fatal("response writer does not support flushing")
		}

		fmt.Fprint(w, "event: state_update\ndata: {\"generated_at\":\"2026-03-08T12:00:00Z\",\"fleet_status\":\"running\",\"running\":[],\"retrying\":[]}\n\n")
		flusher.Flush()
	}))
	defer server.Close()

	c := newTestClient(t, server.URL)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	sub := c.SubscribeSSE(ctx)
	defer sub.Close()

	select {
	case event, ok := <-sub.Events():
		if !ok {
			t.Fatal("SSE channel closed unexpectedly")
		}
		if event.Type != "state_update" {
			t.Fatalf("expected event type state_update, got %q", event.Type)
		}
		state, err := ParseStateEvent(event.Data)
		if err != nil {
			t.Fatalf("failed to parse state: %v", err)
		}
		if state.FleetStatus != "running" {
			t.Fatalf("expected fleet_status running, got %q", state.FleetStatus)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for SSE event")
	}
}

func TestSubscribeSSE_FallbackOn404(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer server.Close()

	c := newTestClient(t, server.URL)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	sub := c.SubscribeSSE(ctx)
	defer sub.Close()

	select {
	case _, ok := <-sub.Events():
		if ok {
			t.Fatal("expected channel to close on 404, but received an event")
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for SSE channel close")
	}
}

func TestSubscribeSSE_IgnoresComments(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)

		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Fatal("response writer does not support flushing")
		}

		fmt.Fprint(w, ": heartbeat\n\nevent: state_update\ndata: {\"generated_at\":\"2026-03-08T12:00:00Z\",\"fleet_status\":\"paused\"}\n\n")
		flusher.Flush()
	}))
	defer server.Close()

	c := newTestClient(t, server.URL)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	sub := c.SubscribeSSE(ctx)
	defer sub.Close()

	select {
	case event, ok := <-sub.Events():
		if !ok {
			t.Fatal("SSE channel closed unexpectedly")
		}
		if event.Type != "state_update" {
			t.Fatalf("expected state_update, got %q", event.Type)
		}
		state, err := ParseStateEvent(event.Data)
		if err != nil {
			t.Fatalf("failed to parse: %v", err)
		}
		if state.FleetStatus != "paused" {
			t.Fatalf("expected fleet_status paused, got %q", state.FleetStatus)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for SSE event")
	}
}

func TestSubscribeSSE_MultipleEvents(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)

		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Fatal("response writer does not support flushing")
		}

		fmt.Fprint(w, "event: state_update\ndata: {\"generated_at\":\"t1\",\"fleet_status\":\"running\"}\n\n")
		flusher.Flush()

		fmt.Fprint(w, "event: state_update\ndata: {\"generated_at\":\"t2\",\"fleet_status\":\"paused\"}\n\n")
		flusher.Flush()
	}))
	defer server.Close()

	c := newTestClient(t, server.URL)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	sub := c.SubscribeSSE(ctx)
	defer sub.Close()

	event1 := <-sub.Events()
	if event1.Type != "state_update" {
		t.Fatalf("event 1: expected state_update, got %q", event1.Type)
	}

	select {
	case event2, ok := <-sub.Events():
		if !ok {
			t.Fatal("channel closed before second event")
		}
		state, _ := ParseStateEvent(event2.Data)
		if state.FleetStatus != "paused" {
			t.Fatalf("event 2: expected fleet_status paused, got %q", state.FleetStatus)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for second event")
	}
}

func TestSubscribeSSE_CloseStopsSubscription(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)

		flusher, ok := w.(http.Flusher)
		if !ok {
			return
		}

		for i := 0; i < 100; i++ {
			fmt.Fprint(w, ": heartbeat\n\n")
			flusher.Flush()
			time.Sleep(50 * time.Millisecond)
		}
	}))
	defer server.Close()

	c := newTestClient(t, server.URL)
	sub := c.SubscribeSSE(context.Background())

	sub.Close()

	timer := time.NewTimer(3 * time.Second)
	defer timer.Stop()
	for {
		select {
		case _, ok := <-sub.Events():
			if !ok {
				return
			}
		case <-timer.C:
			t.Fatal("channel did not close after Close()")
		}
	}
}

func TestSSE_IdleTimeoutTriggersReconnect(t *testing.T) {
	// Server accepts SSE but sends nothing after headers, simulating a dead connection.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		flusher, ok := w.(http.Flusher)
		if !ok {
			return
		}
		flusher.Flush()
		// Hold connection open until client disconnects.
		<-r.Context().Done()
	}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	connCtx, connCancel := context.WithCancel(ctx)
	defer connCancel()

	sub := &SSESubscription{
		url:         server.URL + eventsPath,
		httpClient:  &http.Client{},
		events:      make(chan SSEEvent, 16),
		ctx:         connCtx,
		cancel:      connCancel,
		idleTimeout: 200 * time.Millisecond,
	}

	start := time.Now()
	err := sub.connect()
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected error from idle timeout, got nil")
	}
	if elapsed > 3*time.Second {
		t.Fatalf("connect took %v, expected ~200ms idle timeout", elapsed)
	}
	if elapsed < 150*time.Millisecond {
		t.Fatalf("connect returned too fast (%v), idle timeout may not have fired", elapsed)
	}
}

func TestSSE_ParentContextCancelsGoroutine(t *testing.T) {
	// Server holds SSE connection open with periodic heartbeats.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		flusher, ok := w.(http.Flusher)
		if !ok {
			return
		}
		for {
			fmt.Fprint(w, ": heartbeat\n\n")
			flusher.Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(50 * time.Millisecond):
			}
		}
	}))
	defer server.Close()

	c := newTestClient(t, server.URL)
	ctx, cancel := context.WithCancel(context.Background())
	sub := c.SubscribeSSE(ctx)

	// Cancel the parent context — this should terminate the SSE goroutine.
	cancel()

	timer := time.NewTimer(3 * time.Second)
	defer timer.Stop()
	for {
		select {
		case _, ok := <-sub.Events():
			if !ok {
				return // channel closed — goroutine terminated as expected
			}
		case <-timer.C:
			t.Fatal("SSE goroutine did not terminate after parent context cancellation")
		}
	}
}

func TestParseStateEvent_Valid(t *testing.T) {
	data := `{"generated_at":"2026-03-08T12:00:00Z","fleet_status":"running","running":[],"retrying":[],"counts":{"running":0,"retrying":0}}`
	state, err := ParseStateEvent(data)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if state.FleetStatus != "running" {
		t.Fatalf("expected running, got %q", state.FleetStatus)
	}
	if state.Counts.Running != 0 {
		t.Fatalf("expected 0 running, got %d", state.Counts.Running)
	}
}

func TestParseStateEvent_Invalid(t *testing.T) {
	_, err := ParseStateEvent("not json")
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

func TestSSE_BackoffResetsAfterHealthyConnection(t *testing.T) {
	// Track how many times the server is connected to so we can vary behaviour.
	var connCount int

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != eventsPath {
			http.NotFound(w, r)
			return
		}
		connCount++
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		flusher, ok := w.(http.Flusher)
		if !ok {
			return
		}

		if connCount <= 2 {
			// First two connections: fail immediately (simulate transient errors).
			flusher.Flush()
			return
		}
		if connCount == 3 {
			// Third connection: stay alive long enough for backoff to reset.
			// The test uses a short maxBackoff stand-in via idleTimeout timing.
			// We send heartbeats for 250ms then stop, triggering idle timeout.
			deadline := time.Now().Add(250 * time.Millisecond)
			for time.Now().Before(deadline) {
				fmt.Fprint(w, ": heartbeat\n\n")
				flusher.Flush()
				time.Sleep(25 * time.Millisecond)
			}
			// Stop sending — idle timeout will close this connection.
			<-r.Context().Done()
			return
		}
		// Fourth connection: send a real event so the test can read it.
		fmt.Fprint(w, "event: state_update\ndata: {\"generated_at\":\"t1\",\"fleet_status\":\"running\"}\n\n")
		flusher.Flush()
		<-r.Context().Done()
	}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	sub := &SSESubscription{
		url:               server.URL + eventsPath,
		httpClient:        &http.Client{},
		events:            make(chan SSEEvent, 16),
		ctx:               ctx,
		cancel:            cancel,
		idleTimeout:       100 * time.Millisecond,
		backoffResetAfter: 200 * time.Millisecond,
	}
	go sub.loop()

	// After the third (long-lived) connection, backoff should have reset.
	// If backoff did NOT reset, the wait before the 4th connect would be large
	// (>1s accumulated) and the test would time out within its budget.
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()

	select {
	case ev, ok := <-sub.events:
		if !ok {
			t.Fatal("channel closed before receiving event")
		}
		if ev.Type != "state_update" {
			t.Fatalf("expected state_update, got %q", ev.Type)
		}
	case <-timer.C:
		t.Fatal("timed out — backoff likely not reset after healthy connection")
	}
}
