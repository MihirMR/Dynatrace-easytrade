package flag

import (
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"time"
)

const (
	snapshotFeatureFlagID = "portfolio-insights-enabled"
	snapshotPatternFlagID = "db_not_responding"
)

// snapshotTestFlags returns a fresh store on every call. Every flag starts with
// Enabled == (EnabledAt != nil), the invariant SetEnabled preserves, so a read
// that breaks it has observed a half-written flag.
func snapshotTestFlags() map[string]*Flag {
	enabledAt := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	return map[string]*Flag{
		snapshotFeatureFlagID: {
			ID:           snapshotFeatureFlagID,
			Enabled:      false,
			Name:         "Portfolio insights",
			Description:  "Snapshot test flag",
			IsModifiable: true,
			Tag:          "feature",
			EnabledAt:    nil,
		},
		snapshotPatternFlagID: {
			ID:           snapshotPatternFlagID,
			Enabled:      true,
			Name:         "DB not responding",
			Description:  "Snapshot test flag",
			IsModifiable: true,
			Tag:          "problem_pattern",
			EnabledAt:    &enabledAt,
		},
	}
}

// snapshotMutate reassigns the caller-visible fields of a returned flag,
// flipping Enabled and the presence of EnabledAt. It never writes through
// EnabledAt: a copy shares that pointer with the stored flag, which is safe
// only because SetEnabled replaces the pointer instead of writing through it.
func snapshotMutate(f *Flag) {
	other := time.Date(2030, 6, 1, 0, 0, 0, 0, time.UTC)
	f.Enabled = !f.Enabled
	f.Name = "mutated"
	f.Tag = "mutated"
	if f.EnabledAt == nil {
		f.EnabledAt = &other
	} else {
		f.EnabledAt = nil
	}
}

// snapshotFlagsEqual compares two flags field by field, EnabledAt by instant
// rather than by pointer.
func snapshotFlagsEqual(a, b *Flag) bool {
	if a.ID != b.ID || a.Enabled != b.Enabled || a.Name != b.Name ||
		a.Description != b.Description || a.IsModifiable != b.IsModifiable || a.Tag != b.Tag {
		return false
	}
	if a.EnabledAt == nil || b.EnabledAt == nil {
		return a.EnabledAt == nil && b.EnabledAt == nil
	}
	return a.EnabledAt.Equal(*b.EnabledAt)
}

func snapshotDescribe(f *Flag) string {
	enabledAt := "nil"
	if f.EnabledAt != nil {
		enabledAt = f.EnabledAt.Format(time.RFC3339Nano)
	}
	return fmt.Sprintf("{id=%s enabled=%t name=%q description=%q isModifiable=%t tag=%q enabledAt=%s}",
		f.ID, f.Enabled, f.Name, f.Description, f.IsModifiable, f.Tag, enabledAt)
}

// snapshotAssertStored reads want.ID afresh and fails unless the store still
// holds exactly want.
func snapshotAssertStored(t *testing.T, svc *Service, want *Flag) {
	t.Helper()
	got, ok := svc.GetByID(want.ID)
	if !ok {
		t.Fatalf("GetByID(%s): flag not found", want.ID)
	}
	if !snapshotFlagsEqual(got, want) {
		t.Errorf("stored flag changed: got %s, want %s", snapshotDescribe(got), snapshotDescribe(want))
	}
}

func TestGetByID_returnedValueMutated_storeUnchanged(t *testing.T) {
	t.Run("GetByID", func(t *testing.T) {
		svc := NewService(snapshotTestFlags())
		f, ok := svc.GetByID(snapshotFeatureFlagID)
		if !ok {
			t.Fatalf("GetByID(%s): flag not found", snapshotFeatureFlagID)
		}

		snapshotMutate(f)

		snapshotAssertStored(t, svc, snapshotTestFlags()[snapshotFeatureFlagID])
	})

	t.Run("GetAll", func(t *testing.T) {
		svc := NewService(snapshotTestFlags())
		flags := svc.GetAll()
		if len(flags) != 2 {
			t.Fatalf("GetAll: got %d flags, want 2", len(flags))
		}

		for _, f := range flags {
			snapshotMutate(f)
		}

		for _, want := range snapshotTestFlags() {
			snapshotAssertStored(t, svc, want)
		}
	})

	t.Run("GetByTag", func(t *testing.T) {
		svc := NewService(snapshotTestFlags())
		flags := svc.GetByTag("feature")
		if len(flags) != 1 {
			t.Fatalf("GetByTag(feature): got %d flags, want 1", len(flags))
		}

		snapshotMutate(flags[0])

		snapshotAssertStored(t, svc, snapshotTestFlags()[snapshotFeatureFlagID])
		again := svc.GetByTag("feature")
		if len(again) != 1 || again[0].Tag != "feature" {
			t.Errorf("GetByTag(feature) after mutation: got %d flags, want 1 tagged feature", len(again))
		}
	})

	t.Run("Update", func(t *testing.T) {
		svc := NewService(snapshotTestFlags())
		updated, err := svc.Update(snapshotFeatureFlagID, true)
		if err != nil {
			t.Fatalf("Update(%s, true): unexpected error: %v", snapshotFeatureFlagID, err)
		}
		if !updated.Enabled || updated.EnabledAt == nil {
			t.Fatalf("Update(%s, true): got %s, want enabled with enabledAt set",
				snapshotFeatureFlagID, snapshotDescribe(updated))
		}
		want := *updated

		snapshotMutate(updated)

		snapshotAssertStored(t, svc, &want)
	})
}

// snapshotConsistent reports whether f agrees with itself the way SetEnabled
// leaves every stored flag.
func snapshotConsistent(f *Flag) bool {
	return f.Enabled == (f.EnabledAt != nil)
}

// snapshotCheckFlag verifies one flag returned by a read, then serialises it as
// the handler does and verifies the round trip. It reports only through
// t.Errorf, so reader goroutines may call it.
func snapshotCheckFlag(t *testing.T, source string, f *Flag) bool {
	t.Helper()
	if !snapshotConsistent(f) {
		t.Errorf("%s returned an inconsistent flag %s", source, snapshotDescribe(f))
		return false
	}
	body, err := json.Marshal(f)
	if err != nil {
		t.Errorf("%s: marshal %s: %v", source, snapshotDescribe(f), err)
		return false
	}
	var decoded Flag
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Errorf("%s: unmarshal %s: %v", source, body, err)
		return false
	}
	if decoded.ID != f.ID || decoded.Enabled != f.Enabled || !snapshotConsistent(&decoded) {
		t.Errorf("%s: JSON %s does not match %s", source, body, snapshotDescribe(f))
		return false
	}
	return true
}

// snapshotCheckList is snapshotCheckFlag for the list reads, serialising the
// whole slice as one response body.
func snapshotCheckList(t *testing.T, source string, flags []*Flag, wantLen int) bool {
	t.Helper()
	if len(flags) != wantLen {
		t.Errorf("%s: got %d flags, want %d", source, len(flags), wantLen)
		return false
	}
	for _, f := range flags {
		if !snapshotConsistent(f) {
			t.Errorf("%s returned an inconsistent flag %s", source, snapshotDescribe(f))
			return false
		}
	}
	body, err := json.Marshal(flags)
	if err != nil {
		t.Errorf("%s: marshal: %v", source, err)
		return false
	}
	var decoded []*Flag
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Errorf("%s: unmarshal %s: %v", source, body, err)
		return false
	}
	if len(decoded) != len(flags) {
		t.Errorf("%s: JSON %s holds %d flags, want %d", source, body, len(decoded), len(flags))
		return false
	}
	for i, d := range decoded {
		if d.ID != flags[i].ID || d.Enabled != flags[i].Enabled || !snapshotConsistent(d) {
			t.Errorf("%s: JSON %s does not match %s", source, body, snapshotDescribe(flags[i]))
			return false
		}
	}
	return true
}

// Run under -race as well: against a store that hands out pointers into its
// map, the readers' json.Marshal races with SetEnabled inside Update.
func TestConcurrentUpdateAndRead_snapshotsConsistent(t *testing.T) {
	const (
		writers    = 4
		readers    = 4
		iterations = 200
	)
	ids := []string{snapshotFeatureFlagID, snapshotPatternFlagID}
	svc := NewService(snapshotTestFlags())
	start := make(chan struct{})
	var wg sync.WaitGroup

	for range writers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			for i := range iterations {
				for _, id := range ids {
					if _, err := svc.Update(id, i%2 == 0); err != nil {
						t.Errorf("Update(%s, %t): unexpected error: %v", id, i%2 == 0, err)
						return
					}
				}
			}
		}()
	}

	for range readers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			for range iterations {
				if !snapshotCheckList(t, "GetAll", svc.GetAll(), len(ids)) {
					return
				}
				if !snapshotCheckList(t, "GetByTag(feature)", svc.GetByTag("feature"), 1) {
					return
				}
				f, ok := svc.GetByID(snapshotFeatureFlagID)
				if !ok {
					t.Errorf("GetByID(%s): flag not found", snapshotFeatureFlagID)
					return
				}
				if !snapshotCheckFlag(t, "GetByID", f) {
					return
				}
			}
		}()
	}

	close(start)
	wg.Wait()

	snapshotCheckList(t, "GetAll after concurrent updates", svc.GetAll(), len(ids))
}
