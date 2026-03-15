package client

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net"
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
	// sseIdleTimeout is the maximum duration without receiving any data before
	// the SSE connection is considered dead and a reconnect is triggered.
	sseIdleTimeout = 45 * time.Second
	// sseConnectTimeout is the maximum duration for establishing a TCP+TLS
	// connection before the dial is aborted. This prevents httpClient.Do from
	// hanging indefinitely when the server accepts the TCP handshake but
	// never sends an HTTP response.
	sseConnectTimeout = 10 * time.Second
)

// SSEEvent represents a parsed Server-Sent Event.
type SSEEvent struct {
	Type string
	Data string
}

// SSESubscription manages an SSE connection with auto-reconnect.
type SSESubscription struct {
	url               string
	httpClient        *http.Client
	events            chan SSEEvent
	ctx               context.Context
	cancel            context.CancelFunc
	idleTimeout       time.Duration
	connectTimeout    time.Duration
	backoffResetAfter time.Duration
	minBackoff        time.Duration // test hook; zero → initialBackoff
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
			Transport: &http.Transport{
				DialContext: (&net.Dialer{
					Timeout: sseConnectTimeout,
				}).DialContext,
				ResponseHeaderTimeout: sseConnectTimeout,
			},
		},
		events:            make(chan SSEEvent, 16),
		ctx:               ctx,
		cancel:            cancel,
		idleTimeout:       sseIdleTimeout,
		connectTimeout:    sseConnectTimeout,
		backoffResetAfter: maxBackoff,
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

	base := s.minBackoff
	if base == 0 {
		base = initialBackoff
	}
	backoff := base

	for {
		if err := s.ctx.Err(); err != nil {
			return
		}

		connStart := time.Now()
		err := s.connect()
		if err == errEndpointNotFound {
			return
		}
		if err != nil && s.ctx.Err() != nil {
			return
		}

		// Reset backoff after a healthy connection that lasted longer than
		// the reset threshold, so transient earlier failures don't permanently
		// slow reconnects.
		if time.Since(connStart) >= s.backoffResetAfter {
			backoff = base
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
// the connection drops, the context is cancelled, or the idle timeout fires.
func (s *SSESubscription) connect() error {
	connCtx, connCancel := context.WithCancel(s.ctx)
	defer connCancel()

	req, err := http.NewRequestWithContext(connCtx, http.MethodGet, s.url, nil)
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

	// Start idle timer after connection is established.
	// If no data arrives within the idle timeout the connection is considered
	// dead and connCtx is cancelled, which interrupts the scanner read.
	idleTimer := time.NewTimer(s.idleTimeout)
	defer idleTimer.Stop()
	go func() {
		select {
		case <-idleTimer.C:
			connCancel()
		case <-connCtx.Done():
		}
	}()

	scanner := bufio.NewScanner(resp.Body)
	var eventType string
	var dataLines []string

	for scanner.Scan() {
		if connCtx.Err() != nil {
			return connCtx.Err()
		}

		// Reset idle timer on any received data.
		if !idleTimer.Stop() {
			select {
			case <-idleTimer.C:
			default:
			}
		}
		idleTimer.Reset(s.idleTimeout)

		line := scanner.Text()

		if line == "" {
			if eventType != "" && len(dataLines) > 0 {
				event := SSEEvent{
					Type: eventType,
					Data: strings.Join(dataLines, "\n"),
				}
				select {
				case s.events <- event:
				case <-connCtx.Done():
					return connCtx.Err()
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
