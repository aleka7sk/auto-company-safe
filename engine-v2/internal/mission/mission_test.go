package mission

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/aleka7sk/auto-company-safe/engine-v2/internal/model"
)

func TestCompileIgnoresCheckedBoxesAndAssignsEvidence(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MISSION.md")
	body := `**Product:** Booking Calendar

## Problem
Requests are lost.

## Target User
A manager.

## Definition of Done
- [x] [INV-HOLD-001] One live hold per request is enforced
- [ ] Mobile request flow works in a real browser
- [ ] Human owner approval is recorded
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	contract, err := Compile(path, time.Unix(10, 0))
	if err != nil {
		t.Fatal(err)
	}
	if contract.Product != "Booking Calendar" || contract.ProductSlug != "booking-calendar" {
		t.Fatalf("unexpected product: %+v", contract)
	}
	if len(contract.Criteria) != 3 {
		t.Fatalf("expected 3 criteria, got %d", len(contract.Criteria))
	}
	if contract.Criteria[0].ID != "INV-HOLD-001" {
		t.Fatalf("explicit id was not preserved: %+v", contract.Criteria[0])
	}
	want := []model.EvidenceKind{model.EvidenceRuntimeCommand, model.EvidenceBrowser, model.EvidenceIndependentReview}
	got := contract.Criteria[1].RequiredEvidence
	if len(got) != len(want) {
		t.Fatalf("unexpected UI evidence: %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("evidence[%d]=%s want %s", i, got[i], want[i])
		}
	}
	if len(contract.Criteria[2].RequiredEvidence) != 1 || contract.Criteria[2].RequiredEvidence[0] != model.EvidenceOwnerApproval {
		t.Fatalf("owner criterion not classified: %v", contract.Criteria[2].RequiredEvidence)
	}
}

func TestCompileRejectsDuplicateExplicitID(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MISSION.md")
	body := "**Product:** X\n\n## Definition of Done\n- [ ] [AC-X] one\n- [ ] [AC-X] two\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Compile(path, time.Now()); err == nil {
		t.Fatal("expected duplicate id error")
	}
}
