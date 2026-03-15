package model

import (
	"testing"

	"github.com/humancorp/symphony/tui/types"
)

func TestSyncMetrics_UsedClampedWhenRemainingExceedsCapacity(t *testing.T) {
	tests := []struct {
		name      string
		capacity  int
		remaining int
		wantUsed  int
	}{
		{"normal", 100, 40, 60},
		{"fully used", 100, 0, 100},
		{"remaining equals capacity", 100, 100, 0},
		{"remaining exceeds capacity", 100, 150, 0},
		{"zero capacity zero remaining", 0, 0, 0},
		{"zero capacity positive remaining", 0, 5, 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := &Model{
				state: &types.State{
					RateLimits: &types.RateLimits{
						PrimaryBucket: &types.Bucket{
							Capacity:  tt.capacity,
							Remaining: tt.remaining,
						},
						SecondaryBucket: &types.Bucket{
							Capacity:  tt.capacity,
							Remaining: tt.remaining,
						},
					},
				},
			}

			m.syncMetrics()

			if len(m.limits) < 2 {
				t.Fatalf("expected 2 rate limits, got %d", len(m.limits))
			}
			if m.limits[0].Used != tt.wantUsed {
				t.Errorf("Primary Used = %d, want %d", m.limits[0].Used, tt.wantUsed)
			}
			if m.limits[1].Used != tt.wantUsed {
				t.Errorf("Secondary Used = %d, want %d", m.limits[1].Used, tt.wantUsed)
			}
		})
	}
}
