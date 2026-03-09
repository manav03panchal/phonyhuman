package client

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/humancorp/symphony/tui/types"
)

const (
	// initialBackoff is the starting delay before reconnecting after a failure.
	initialBackoff = 1 * time.Second
	// maxBackoff caps the exponential backoff delay.
	maxBackoff = 30 * time.Second
	// backoffFactor is the multiplier applied on each consecutive failure.
	backoffFactor = 2.0
	// eventsPath is the SSE endpoint path.
	eventsPath = "/api/v1/events"
)

// SSEEvent represents a parsed Server-Sent Event.
type SSEEvent struct {
	Type string
	Data string
}

// SSESubscription manages an SSE connection with auto-reconnect.
type SSESubscription struct {
	url        string
	httpClient *http.Client
	events     chan SSEEvent
	ctx        context.Context
	cancel     context.CancelFunc
}

// SubscribeSSE connects to the SSE endpoint and returns a subscription.
// Events are delivered on the returned channel. The connection auto-reconnects
// with exponential backoff on failure. If the endpoint returns 404 the
// subscription closes the channel and returns, signalling the caller to fall
// back to HTTP polling.
func (c *Client) SubscribeSSE(ctx context.Context) *SSESubscription {
	ctx, cancel := context.WithCancel(ctx)
	sub := &SSESubscription{
		url: c.baseURL + eventsPath,
		httpClient: &http.Client{
			// No timeout — SSE connections are long-lived.
		},
		events: make(chan SSEEvent, 16),
		ctx:    ctx,
		cancel: cancel,
	}
	go sub.loop()
	return sub
}

// Events returns the channel that delivers parsed SSE events.
func (s *SSESubscription) Events() <-chan SSEEvent {
	return s.events
}

// Close shuts down the SSE subscription.
func (s *SSESubscription) Close() {
	s.cancel()
}

// loop runs the reconnect loop. It connects, reads events, and reconnects
// with exponential backoff on any error. A 404 response terminates the loop
// so the caller can fall back to polling.
func (s *SSESubscription) loop() {
	defer close(s.events)

	backoff := initialBackoff

	for {
		if err := s.ctx.Err(); err != nil {
			return
		}

		err := s.connect()
		if err == errEndpointNotFound {
			return
		}
		if err != nil && s.ctx.Err() != nil {
			return
		}

		select {
		case <-s.ctx.Done():
			return
		case <-time.After(backoff):
		}

		backoff = time.Duration(math.Min(
			float64(backoff)*backoffFactor,
			float64(maxBackoff),
		))
	}
}

var errEndpointNotFound = fmt.Errorf("SSE endpoint returned 404")

// connect performs a single SSE connection and reads events until
// the connection drops or the context is cancelled.
func (s *SSESubscription) connect() error {
	req, err := http.NewRequestWithContext(s.ctx, http.MethodGet, s.url, nil)
	if err != nil {
		return fmt.Errorf("create SSE request: %w", err)
	}
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Cache-Control", "no-cache")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("SSE connect: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return errEndpointNotFound
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("SSE unexpected status: %d", resp.StatusCode)
	}

	scanner := bufio.NewScanner(resp.Body)
	var eventType string
	var dataLines []string

	for scanner.Scan() {
		if s.ctx.Err() != nil {
			return s.ctx.Err()
		}

		line := scanner.Text()

		if line == "" {
			if eventType != "" && len(dataLines) > 0 {
				event := SSEEvent{
					Type: eventType,
					Data: strings.Join(dataLines, "\n"),
				}
				select {
				case s.events <- event:
				case <-s.ctx.Done():
					return s.ctx.Err()
				}
			}
			eventType = ""
			dataLines = nil
			continue
		}

		if strings.HasPrefix(line, ":") {
			continue
		}

		if strings.HasPrefix(line, "event: ") {
			eventType = strings.TrimPrefix(line, "event: ")
		} else if strings.HasPrefix(line, "data: ") {
			dataLines = append(dataLines, strings.TrimPrefix(line, "data: "))
		}
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("SSE read: %w", err)
	}
	return nil
}

// ParseStateEvent decodes a state_update SSE event's data into a types.State.
func ParseStateEvent(data string) (*types.State, error) {
	var state types.State
	if err := json.Unmarshal([]byte(data), &state); err != nil {
		return nil, fmt.Errorf("parse state_update: %w", err)
	}
	return &state, nil
}
