package client

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
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
		url:            server.URL + eventsPath,
		httpClient:     &http.Client{},
		events:         make(chan SSEEvent, 16),
		ctx:            connCtx,
		cancel:         connCancel,
		idleTimeout:    200 * time.Millisecond,
		connectTimeout: 10 * time.Second,
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

func TestSSE_ConnectTimeoutFires(t *testing.T) {
	// Create a TCP listener that accepts connections but never sends any data,
	// simulating a server that hangs after the TCP handshake.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to create listener: %v", err)
	}
	defer ln.Close()

	// Accept connections in the background but hold them open silently.
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			// Hold connection open — never write anything.
			go func(c net.Conn) {
				<-time.After(30 * time.Second)
				c.Close()
			}(conn)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	connCtx, connCancel := context.WithCancel(ctx)
	defer connCancel()

	connectTimeout := 300 * time.Millisecond
	sub := &SSESubscription{
		url: "http://" + ln.Addr().String() + eventsPath,
		httpClient: &http.Client{
			Transport: &http.Transport{
				DialContext: (&net.Dialer{
					Timeout: connectTimeout,
				}).DialContext,
				ResponseHeaderTimeout: connectTimeout,
			},
		},
		events:         make(chan SSEEvent, 16),
		ctx:            connCtx,
		cancel:         connCancel,
		idleTimeout:    45 * time.Second,
		connectTimeout: connectTimeout,
	}

	start := time.Now()
	err = sub.connect()
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected error from connect timeout, got nil")
	}
	if elapsed > 3*time.Second {
		t.Fatalf("connect took %v, expected to fail within ~300ms", elapsed)
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

func TestSSE_RetriesOnServerError(t *testing.T) {
	// Server returns 500 for first two attempts, then sends a real event.
	var connCount int32

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != eventsPath {
			http.NotFound(w, r)
			return
		}
		n := atomic.AddInt32(&connCount, 1)
		if n <= 2 {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		flusher, ok := w.(http.Flusher)
		if !ok {
			return
		}
		fmt.Fprint(w, "event: state_update\ndata: {\"generated_at\":\"t1\",\"fleet_status\":\"running\"}\n\n")
		flusher.Flush()
		<-r.Context().Done()
	}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	sub := &SSESubscription{
		url:               server.URL + eventsPath,
		httpClient:        &http.Client{},
		events:            make(chan SSEEvent, 16),
		ctx:               ctx,
		cancel:            cancel,
		idleTimeout:       5 * time.Second,
		minBackoff:        50 * time.Millisecond,
		backoffResetAfter: 30 * time.Second,
	}
	go sub.loop()

	select {
	case ev, ok := <-sub.events:
		if !ok {
			t.Fatal("channel closed before receiving event")
		}
		if ev.Type != "state_update" {
			t.Fatalf("expected state_update, got %q", ev.Type)
		}
		got := atomic.LoadInt32(&connCount)
		if got < 3 {
			t.Fatalf("expected at least 3 connection attempts, got %d", got)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for event after retries")
	}
}

func TestSSE_BackoffIncreasesExponentially(t *testing.T) {
	// Server accepts each connection and closes immediately (EOF), triggering
	// retries. We record timestamps to verify that gaps between attempts grow.
	var mu sync.Mutex
	var timestamps []time.Time

	const wantAttempts = 4

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != eventsPath {
			http.NotFound(w, r)
			return
		}
		mu.Lock()
		timestamps = append(timestamps, time.Now())
		mu.Unlock()
		// Return 200 + flush then close → EOF on client side → reconnect.
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
	}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	sub := &SSESubscription{
		url:               server.URL + eventsPath,
		httpClient:        &http.Client{},
		events:            make(chan SSEEvent, 16),
		ctx:               ctx,
		cancel:            cancel,
		idleTimeout:       5 * time.Second,
		minBackoff:        50 * time.Millisecond,
		backoffResetAfter: 30 * time.Second,
	}
	go sub.loop()

	// Wait until enough connection attempts have occurred.
	deadline := time.After(4 * time.Second)
	for {
		mu.Lock()
		n := len(timestamps)
		mu.Unlock()
		if n >= wantAttempts {
			break
		}
		select {
		case <-deadline:
			mu.Lock()
			n = len(timestamps)
			mu.Unlock()
			t.Fatalf("only got %d connection attempts, wanted %d", n, wantAttempts)
		case <-time.After(10 * time.Millisecond):
		}
	}
	cancel()

	mu.Lock()
	defer mu.Unlock()

	// With minBackoff=50ms and factor=2, the gaps should roughly double each
	// time: 50ms, 100ms, 200ms. Verify the last gap is at least 2× the first
	// gap, allowing generous tolerance for scheduling jitter.
	firstGap := timestamps[1].Sub(timestamps[0])
	lastGap := timestamps[len(timestamps)-1].Sub(timestamps[len(timestamps)-2])
	if lastGap < firstGap*2 {
		t.Fatalf("backoff did not increase: first gap %v, last gap %v (expected last >= 2× first)", firstGap, lastGap)
	}
}

func TestSSE_ReconnectsAfterServerRecovery(t *testing.T) {
	// Server starts "down" (503), then switches to serving events. The client
	// should keep retrying until the server recovers, then deliver the event.
	var serverUp int32

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != eventsPath {
			http.NotFound(w, r)
			return
		}
		if atomic.LoadInt32(&serverUp) == 0 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		flusher, ok := w.(http.Flusher)
		if !ok {
			return
		}
		fmt.Fprint(w, "event: state_update\ndata: {\"generated_at\":\"t1\",\"fleet_status\":\"running\"}\n\n")
		flusher.Flush()
		<-r.Context().Done()
	}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	sub := &SSESubscription{
		url:               server.URL + eventsPath,
		httpClient:        &http.Client{},
		events:            make(chan SSEEvent, 16),
		ctx:               ctx,
		cancel:            cancel,
		idleTimeout:       5 * time.Second,
		minBackoff:        50 * time.Millisecond,
		backoffResetAfter: 30 * time.Second,
	}
	go sub.loop()

	// Let client fail a few times, then bring server up.
	time.Sleep(200 * time.Millisecond)
	atomic.StoreInt32(&serverUp, 1)

	select {
	case ev, ok := <-sub.events:
		if !ok {
			t.Fatal("channel closed before receiving event")
		}
		if ev.Type != "state_update" {
			t.Fatalf("expected state_update, got %q", ev.Type)
		}
	case <-ctx.Done():
		t.Fatal("timed out — client did not reconnect after server recovery")
	}
}
