package policy

import (
	"testing"
	"time"

	"github.com/aleka7sk/auto-company-safe/engine-v2/internal/model"
)

func TestValidateEvidenceRejectsImplementerCertification(t *testing.T) {
	zero := 0
	record := model.EvidenceRecord{CriterionID: "AC-1", Kind: model.EvidenceRuntimeCommand, Actor: "implementer", Status: model.EvidencePassed, Command: "go test ./...", ExitCode: &zero}
	if err := ValidateEvidence(record); err == nil {
		t.Fatal("expected implementer evidence to be rejected")
	}
}

func TestCompletionRequiresAllEvidenceAndNoBlockers(t *testing.T) {
	contract := model.MissionContract{Criteria: []model.Criterion{{ID: "AC-1", Text: "UI", RequiredEvidence: []model.EvidenceKind{model.EvidenceRuntimeCommand, model.EvidenceBrowser, model.EvidenceIndependentReview}}}}
	zero := 0
	evidence := []model.EvidenceRecord{
		{CriterionID: "AC-1", Kind: model.EvidenceRuntimeCommand, Actor: "runtime", Status: model.EvidencePassed, Command: "npm test", ExitCode: &zero},
		{CriterionID: "AC-1", Kind: model.EvidenceBrowser, Actor: "browser", Status: model.EvidencePassed, Artifact: "trace.zip", ArtifactSHA: "abc"},
		{CriterionID: "AC-1", Kind: model.EvidenceIndependentReview, Actor: "verifier", Status: model.EvidencePassed},
	}
	state := model.RunState{}
	report := Completion(contract, state, evidence)
	if !report.Complete {
		t.Fatalf("expected complete: %+v", report)
	}
	state.Findings = []model.Finding{{ID: "F-1", Severity: model.SeverityP1, Status: model.FindingOpen}}
	report = Completion(contract, state, evidence)
	if report.Complete || len(report.OpenBlockers) != 1 {
		t.Fatalf("P1 must block completion: %+v", report)
	}
}

func TestSelectSliceHardCapsCriteria(t *testing.T) {
	contract := model.MissionContract{Criteria: []model.Criterion{{ID: "A"}, {ID: "B"}, {ID: "C"}}}
	slice, err := SelectSlice(contract, model.RunState{}, nil, 2, time.Unix(1, 0))
	if err != nil {
		t.Fatal(err)
	}
	if len(slice.CriterionIDs) != 2 || slice.CriterionIDs[0] != "A" || slice.CriterionIDs[1] != "B" {
		t.Fatalf("unexpected slice: %+v", slice)
	}
}
