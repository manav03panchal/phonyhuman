package contract

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/humancorp/symphony/tui/types"
)

// goldenDir returns the absolute path to the shared contract/golden directory.
func goldenDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("unable to determine test file path")
	}
	return filepath.Join(filepath.Dir(file), "..", "..", "contract", "golden")
}

func readGolden(t *testing.T, filename string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(goldenDir(t), filename))
	if err != nil {
		t.Fatalf("failed to read golden file %s: %v", filename, err)
	}
	return data
}

func TestFullStateDeserialization(t *testing.T) {
	data := readGolden(t, "state_full.json")

	var state types.State
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatalf("failed to unmarshal state_full.json: %v", err)
	}

	// Top-level fields
	if state.GeneratedAt != "2026-03-08T12:00:00Z" {
		t.Errorf("GeneratedAt = %q, want %q", state.GeneratedAt, "2026-03-08T12:00:00Z")
	}
	if state.MaxAgents != 5 {
		t.Errorf("MaxAgents = %d, want 5", state.MaxAgents)
	}
	if state.FleetStatus != "running" {
		t.Errorf("FleetStatus = %q, want %q", state.FleetStatus, "running")
	}
	if state.FleetPausedUntil != nil {
		t.Errorf("FleetPausedUntil = %v, want nil", state.FleetPausedUntil)
	}
	if state.FleetPauseReason != nil {
		t.Errorf("FleetPauseReason = %v, want nil", state.FleetPauseReason)
	}

	// Counts
	if state.Counts.Running != 1 {
		t.Errorf("Counts.Running = %d, want 1", state.Counts.Running)
	}
	if state.Counts.Retrying != 1 {
		t.Errorf("Counts.Retrying = %d, want 1", state.Counts.Retrying)
	}

	// Running entries
	if len(state.Running) != 1 {
		t.Fatalf("Running length = %d, want 1", len(state.Running))
	}
	agent := state.Running[0]
	if agent.IssueID != "uuid-issue-1" {
		t.Errorf("Running[0].IssueID = %q, want %q", agent.IssueID, "uuid-issue-1")
	}
	if agent.IssueIdentifier != "HUM-100" {
		t.Errorf("Running[0].IssueIdentifier = %q, want %q", agent.IssueIdentifier, "HUM-100")
	}
	if agent.State != "In Progress" {
		t.Errorf("Running[0].State = %q, want %q", agent.State, "In Progress")
	}
	if agent.SessionID != "sess-abc" {
		t.Errorf("Running[0].SessionID = %q, want %q", agent.SessionID, "sess-abc")
	}
	if agent.TurnCount != 5 {
		t.Errorf("Running[0].TurnCount = %d, want 5", agent.TurnCount)
	}
	if agent.Model == nil || *agent.Model != "claude-opus-4-6" {
		t.Errorf("Running[0].Model = %v, want %q", agent.Model, "claude-opus-4-6")
	}

	// Tokens (nested)
	if agent.Tokens.InputTokens != 10000 {
		t.Errorf("Tokens.InputTokens = %d, want 10000", agent.Tokens.InputTokens)
	}
	if agent.Tokens.OutputTokens != 2000 {
		t.Errorf("Tokens.OutputTokens = %d, want 2000", agent.Tokens.OutputTokens)
	}
	if agent.Tokens.TotalTokens != 12000 {
		t.Errorf("Tokens.TotalTokens = %d, want 12000", agent.Tokens.TotalTokens)
	}
	if agent.Tokens.CacheReadTokens != 5000 {
		t.Errorf("Tokens.CacheReadTokens = %d, want 5000", agent.Tokens.CacheReadTokens)
	}
	if agent.Tokens.CostUSD != 0.42 {
		t.Errorf("Tokens.CostUSD = %f, want 0.42", agent.Tokens.CostUSD)
	}

	// OTel metrics
	if agent.LinesChanged != 99 {
		t.Errorf("LinesChanged = %d, want 99", agent.LinesChanged)
	}
	if agent.CommitsCount != 3 {
		t.Errorf("CommitsCount = %d, want 3", agent.CommitsCount)
	}
	if agent.PRsCount != 1 {
		t.Errorf("PRsCount = %d, want 1", agent.PRsCount)
	}
	if agent.ToolCalls != 15 {
		t.Errorf("ToolCalls = %d, want 15", agent.ToolCalls)
	}
	if agent.ToolAvgDurationMs != 250 {
		t.Errorf("ToolAvgDurationMs = %d, want 250", agent.ToolAvgDurationMs)
	}
	if agent.APIErrors != 1 {
		t.Errorf("APIErrors = %d, want 1", agent.APIErrors)
	}
	if agent.ActiveTimeSeconds != 300 {
		t.Errorf("ActiveTimeSeconds = %d, want 300", agent.ActiveTimeSeconds)
	}

	// Retrying entries
	if len(state.Retrying) != 1 {
		t.Fatalf("Retrying length = %d, want 1", len(state.Retrying))
	}
	retry := state.Retrying[0]
	if retry.IssueID != "uuid-issue-2" {
		t.Errorf("Retrying[0].IssueID = %q, want %q", retry.IssueID, "uuid-issue-2")
	}
	if retry.IssueIdentifier != "HUM-200" {
		t.Errorf("Retrying[0].IssueIdentifier = %q, want %q", retry.IssueIdentifier, "HUM-200")
	}
	if retry.Attempt != 3 {
		t.Errorf("Retrying[0].Attempt = %d, want 3", retry.Attempt)
	}
	if retry.DueAt != "2026-03-08T12:05:00Z" {
		t.Errorf("Retrying[0].DueAt = %q, want %q", retry.DueAt, "2026-03-08T12:05:00Z")
	}
	if retry.Error != "rate limited" {
		t.Errorf("Retrying[0].Error = %q, want %q", retry.Error, "rate limited")
	}

	// AgentTotals
	totals := state.AgentTotals
	if totals.InputTokens != 50000 {
		t.Errorf("AgentTotals.InputTokens = %d, want 50000", totals.InputTokens)
	}
	if totals.OutputTokens != 15000 {
		t.Errorf("AgentTotals.OutputTokens = %d, want 15000", totals.OutputTokens)
	}
	if totals.TotalTokens != 65000 {
		t.Errorf("AgentTotals.TotalTokens = %d, want 65000", totals.TotalTokens)
	}
	if totals.CacheReadTokens != 30000 {
		t.Errorf("AgentTotals.CacheReadTokens = %d, want 30000", totals.CacheReadTokens)
	}
	if totals.CacheCreationTokens != 10000 {
		t.Errorf("AgentTotals.CacheCreationTokens = %d, want 10000", totals.CacheCreationTokens)
	}
	if totals.CostUSD != 2.50 {
		t.Errorf("AgentTotals.CostUSD = %f, want 2.50", totals.CostUSD)
	}
	if totals.SecondsRunning != 1800 {
		t.Errorf("AgentTotals.SecondsRunning = %d, want 1800", totals.SecondsRunning)
	}
	if totals.LinesChanged != 250 {
		t.Errorf("AgentTotals.LinesChanged = %d, want 250", totals.LinesChanged)
	}
	if totals.CommitsCount != 10 {
		t.Errorf("AgentTotals.CommitsCount = %d, want 10", totals.CommitsCount)
	}
	if totals.PRsCount != 3 {
		t.Errorf("AgentTotals.PRsCount = %d, want 3", totals.PRsCount)
	}
	if totals.ToolCalls != 50 {
		t.Errorf("AgentTotals.ToolCalls = %d, want 50", totals.ToolCalls)
	}
	if totals.ToolAvgDurationMs != 200 {
		t.Errorf("AgentTotals.ToolAvgDurationMs = %d, want 200", totals.ToolAvgDurationMs)
	}
	if totals.APIErrors != 5 {
		t.Errorf("AgentTotals.APIErrors = %d, want 5", totals.APIErrors)
	}
	if totals.ActiveTimeSeconds != 1500 {
		t.Errorf("AgentTotals.ActiveTimeSeconds = %d, want 1500", totals.ActiveTimeSeconds)
	}

	// RateLimits
	if state.RateLimits == nil {
		t.Fatal("RateLimits is nil, want non-nil")
	}
	if state.RateLimits.LimitID != "rl-001" {
		t.Errorf("RateLimits.LimitID = %q, want %q", state.RateLimits.LimitID, "rl-001")
	}
	if state.RateLimits.PrimaryBucket == nil {
		t.Fatal("RateLimits.PrimaryBucket is nil, want non-nil")
	}
	if state.RateLimits.PrimaryBucket.Capacity != 1000 {
		t.Errorf("PrimaryBucket.Capacity = %d, want 1000", state.RateLimits.PrimaryBucket.Capacity)
	}
	if state.RateLimits.PrimaryBucket.Remaining != 750 {
		t.Errorf("PrimaryBucket.Remaining = %d, want 750", state.RateLimits.PrimaryBucket.Remaining)
	}
	if state.RateLimits.SecondaryBucket == nil {
		t.Fatal("RateLimits.SecondaryBucket is nil, want non-nil")
	}
	if state.RateLimits.SecondaryBucket.Capacity != 5000 {
		t.Errorf("SecondaryBucket.Capacity = %d, want 5000", state.RateLimits.SecondaryBucket.Capacity)
	}
	if state.RateLimits.SecondaryBucket.Remaining != 4200 {
		t.Errorf("SecondaryBucket.Remaining = %d, want 4200", state.RateLimits.SecondaryBucket.Remaining)
	}
	if state.RateLimits.Credits != 100.0 {
		t.Errorf("RateLimits.Credits = %f, want 100.0", state.RateLimits.Credits)
	}
}

func TestEmptyStateDeserialization(t *testing.T) {
	data := readGolden(t, "state_empty.json")

	var state types.State
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatalf("failed to unmarshal state_empty.json: %v", err)
	}

	if state.Counts.Running != 0 {
		t.Errorf("Counts.Running = %d, want 0", state.Counts.Running)
	}
	if state.Counts.Retrying != 0 {
		t.Errorf("Counts.Retrying = %d, want 0", state.Counts.Retrying)
	}
	if len(state.Running) != 0 {
		t.Errorf("Running length = %d, want 0", len(state.Running))
	}
	if len(state.Retrying) != 0 {
		t.Errorf("Retrying length = %d, want 0", len(state.Retrying))
	}
	if state.RateLimits != nil {
		t.Errorf("RateLimits = %v, want nil", state.RateLimits)
	}
	if state.MaxAgents != 5 {
		t.Errorf("MaxAgents = %d, want 5", state.MaxAgents)
	}
	if state.FleetStatus != "running" {
		t.Errorf("FleetStatus = %q, want %q", state.FleetStatus, "running")
	}
}

func TestErrorStateDeserialization(t *testing.T) {
	data := readGolden(t, "state_error.json")

	var state types.State
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatalf("failed to unmarshal state_error.json: %v", err)
	}

	if state.GeneratedAt != "2026-03-08T12:00:00Z" {
		t.Errorf("GeneratedAt = %q, want %q", state.GeneratedAt, "2026-03-08T12:00:00Z")
	}
	if state.Error == nil {
		t.Fatal("Error is nil, want non-nil")
	}
	if state.Error.Code != "snapshot_timeout" {
		t.Errorf("Error.Code = %q, want %q", state.Error.Code, "snapshot_timeout")
	}
	if state.Error.Message != "Snapshot timed out" {
		t.Errorf("Error.Message = %q, want %q", state.Error.Message, "Snapshot timed out")
	}
}

// TestRoundTripPreservesAllFields verifies that marshaling a State back to JSON
// preserves every key from the golden file. This catches fields that exist in
// the golden file but silently fall through Go unmarshaling (e.g., misspelled
// json tags or missing struct fields).
func TestRoundTripPreservesAllFields(t *testing.T) {
	data := readGolden(t, "state_full.json")

	var state types.State
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	remarshaled, err := json.Marshal(state)
	if err != nil {
		t.Fatalf("remarshal: %v", err)
	}

	var golden map[string]interface{}
	var roundtrip map[string]interface{}
	if err := json.Unmarshal(data, &golden); err != nil {
		t.Fatalf("golden parse: %v", err)
	}
	if err := json.Unmarshal(remarshaled, &roundtrip); err != nil {
		t.Fatalf("roundtrip parse: %v", err)
	}

	missingKeys := findMissingKeys(golden, roundtrip, "")
	for _, key := range missingKeys {
		t.Errorf("golden key %q lost after round-trip through types.State", key)
	}
}

// findMissingKeys returns dotted key paths present in expected but absent in actual.
func findMissingKeys(expected, actual map[string]interface{}, prefix string) []string {
	var missing []string
	for key, expectedVal := range expected {
		fullKey := key
		if prefix != "" {
			fullKey = prefix + "." + key
		}

		actualVal, ok := actual[key]
		if !ok {
			missing = append(missing, fullKey)
			continue
		}

		// Recurse into nested objects
		if expectedMap, ok := expectedVal.(map[string]interface{}); ok {
			if actualMap, ok := actualVal.(map[string]interface{}); ok {
				missing = append(missing, findMissingKeys(expectedMap, actualMap, fullKey)...)
			}
		}

		// Recurse into arrays of objects
		if expectedArr, ok := expectedVal.([]interface{}); ok && len(expectedArr) > 0 {
			if expectedElem, ok := expectedArr[0].(map[string]interface{}); ok {
				if actualArr, ok := actualVal.([]interface{}); ok && len(actualArr) > 0 {
					if actualElem, ok := actualArr[0].(map[string]interface{}); ok {
						missing = append(missing, findMissingKeys(expectedElem, actualElem, fullKey+"[]")...)
					}
				}
			}
		}
	}
	return missing
}
