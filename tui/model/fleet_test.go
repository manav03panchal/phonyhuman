package model

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/humancorp/symphony/tui/client"
	"github.com/humancorp/symphony/tui/types"
)

// newTestModel creates a Model with a mock client for testing.
func newTestModel(t *testing.T, handler http.HandlerFunc) Model {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)

	c, err := client.New(srv.URL)
	if err != nil {
		t.Fatalf("client.New: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	return Model{
		client: c,
		metrics: types.AgentMetrics{
			FleetStatus: "running",
		},
		project: types.ProjectInfo{
			DashboardURL: srv.URL,
			RefreshSec:   10,
		},
		state: &types.State{
			FleetStatus: "running",
			Counts:      types.Counts{Running: 1},
			Running: []types.AgentEntry{
				{
					IssueID:         "test-123",
					IssueIdentifier: "HUM-10",
					State:           "running",
				},
			},
		},
		ctx:    ctx,
		cancel: cancel,
		useSSE: false,
		agents: []types.Agent{
			{
				ID:    "HUM-10",
				Stage: "running",
				Status: types.StatusActive,
			},
		},
	}
}

func TestPausePrompt_PKeyShowsConfirmation(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	// Press 'p' on a running fleet
	result, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'p'}})
	model := result.(Model)

	if model.prompt != promptConfirmPause {
		t.Errorf("prompt = %d, want promptConfirmPause (%d)", model.prompt, promptConfirmPause)
	}
}

func TestResumePrompt_PKeyWhenPaused(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	m.state.FleetStatus = "paused"

	result, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'p'}})
	model := result.(Model)

	if model.prompt != promptConfirmResume {
		t.Errorf("prompt = %d, want promptConfirmResume (%d)", model.prompt, promptConfirmResume)
	}
}

func TestPauseConfirm_YKeyTriggersPause(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})
	m.prompt = promptConfirmPause

	result, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	model := result.(Model)

	if model.prompt != promptNone {
		t.Error("prompt should be cleared after confirmation")
	}
	if cmd == nil {
		t.Error("expected a tea.Cmd for pause action")
	}
}

func TestPauseCancel_NKeyClears(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	m.prompt = promptConfirmPause

	result, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'n'}})
	model := result.(Model)

	if model.prompt != promptNone {
		t.Error("prompt should be cleared after cancellation")
	}
}

func TestFleetActionMsg_SetsLastActionErr(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(types.State{FleetStatus: "running"})
	})

	errMsg := fleetActionMsg{err: nil}
	result, _ := m.Update(errMsg)
	model := result.(Model)

	if model.lastActionErr != nil {
		t.Errorf("lastActionErr = %v, want nil", model.lastActionErr)
	}
}

func TestTmuxResultMsg_SetsStatusText(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	m.view = viewDetail
	m.detailAgentID = "HUM-10"

	result, _ := m.Update(tmuxResultMsg{err: nil})
	model := result.(Model)

	if model.statusText != "" {
		t.Errorf("statusText = %q, want empty on success", model.statusText)
	}
}

func TestTmuxResultMsg_ErrorSetsStatusText(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	m.view = viewDetail
	m.detailAgentID = "HUM-10"

	result, _ := m.Update(tmuxResultMsg{err: fmt.Errorf("tmux not found in PATH")})
	model := result.(Model)

	if model.statusText != "tmux not found in PATH" {
		t.Errorf("statusText = %q, want %q", model.statusText, "tmux not found in PATH")
	}
}

func TestDetailView_EnterOpensDetail(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(types.IssueDetail{})
	})

	result, _ := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	model := result.(Model)

	if model.view != viewDetail {
		t.Errorf("view = %d, want viewDetail (%d)", model.view, viewDetail)
	}
	if model.detailAgentID != "HUM-10" {
		t.Errorf("detailAgentID = %q, want HUM-10", model.detailAgentID)
	}
}

func TestDetailView_EscReturns(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	m.view = viewDetail
	m.detailAgentID = "HUM-10"

	result, _ := m.Update(tea.KeyMsg{Type: tea.KeyEscape})
	model := result.(Model)

	if model.view != viewDashboard {
		t.Errorf("view = %d, want viewDashboard (%d)", model.view, viewDashboard)
	}
	if model.detailAgentID != "" {
		t.Errorf("detailAgentID = %q, want empty", model.detailAgentID)
	}
}

func TestStateMsg_ClearsLastActionErr(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	m.lastActionErr = fmt.Errorf("previous error")

	st := &types.State{
		FleetStatus: "running",
		Counts:      types.Counts{Running: 0},
	}
	result, _ := m.Update(stateMsg{state: st})
	model := result.(Model)

	if model.lastActionErr != nil {
		t.Error("stateMsg should clear lastActionErr")
	}
}

func TestCursorNavigation_DownAndUp(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	// Add a second agent for navigation testing
	m.agents = append(m.agents, types.Agent{
		ID:     "HUM-11",
		Stage:  "running",
		Status: types.StatusActive,
	})

	// Move down
	result, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	model := result.(Model)
	if model.cursor != 1 {
		t.Errorf("cursor = %d, want 1 after down", model.cursor)
	}

	// Move up
	result, _ = model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	model = result.(Model)
	if model.cursor != 0 {
		t.Errorf("cursor = %d, want 0 after up", model.cursor)
	}
}

func TestQuitPrompt_ConfirmQuits(t *testing.T) {
	m := newTestModel(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	// Press 'q' to show quit prompt
	result, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'q'}})
	model := result.(Model)
	if model.prompt != promptConfirmQuit {
		t.Errorf("prompt = %d, want promptConfirmQuit (%d)", model.prompt, promptConfirmQuit)
	}

	// Confirm with 'y'
	result, cmd := model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	// cmd should be tea.Quit
	if cmd == nil {
		t.Error("expected a tea.Cmd for quit action")
	}
	_ = result
}
