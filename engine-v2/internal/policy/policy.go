package policy

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/aleka7sk/auto-company-safe/engine-v2/internal/model"
)

func DefaultConfig(productRoot string) model.Config {
	return model.Config{
		SchemaVersion:          model.SchemaVersion,
		ProductRoot:            productRoot,
		MaxCriteriaPerSlice:    2,
		MaxChangedFiles:        20,
		MaxChangedLines:        2000,
		MaxAgentTurns:          30,
		MaxCycleBudgetUSD:      10,
		MaxReviewFixCycles:     2,
		RequireTrackedProduct:  true,
		RequireBrowserForUI:    true,
		RequireIndependentTest: true,
	}
}

func SelectSlice(contract model.MissionContract, state model.RunState, evidence []model.EvidenceRecord, maxCriteria int, now time.Time) (model.Slice, error) {
	if maxCriteria <= 0 {
		return model.Slice{}, errors.New("max criteria per slice must be positive")
	}
	passed := PassedCriterionIDs(contract, evidence)
	var pending []string
	for _, criterion := range contract.Criteria {
		if !passed[criterion.ID] {
			pending = append(pending, criterion.ID)
		}
		if len(pending) == maxCriteria {
			break
		}
	}
	if len(pending) == 0 {
		return model.Slice{}, errors.New("no pending criteria")
	}
	id := fmt.Sprintf("SLICE-%03d", len(state.Slices)+1)
	return model.Slice{
		ID:           id,
		CriterionIDs: pending,
		Status:       model.SlicePlanned,
		CreatedAt:    now.UTC(),
		UpdatedAt:    now.UTC(),
	}, nil
}

func ValidateEvidence(record model.EvidenceRecord) error {
	if record.CriterionID == "" {
		return errors.New("criterion id is required")
	}
	if record.Status != model.EvidencePassed && record.Status != model.EvidenceFailed {
		return fmt.Errorf("invalid evidence status %q", record.Status)
	}
	actor := strings.ToLower(strings.TrimSpace(record.Actor))
	if actor == "" {
		return errors.New("evidence actor is required")
	}
	if actor == "model" || actor == "assistant" || actor == "implementer" {
		return errors.New("an implementation model cannot certify acceptance evidence")
	}
	switch record.Kind {
	case model.EvidenceRuntimeCommand:
		if actor != "runtime" {
			return errors.New("runtime_command evidence must be recorded by actor=runtime")
		}
		if record.Command == "" || record.ExitCode == nil {
			return errors.New("runtime_command evidence requires command and exit_code")
		}
		if record.Status == model.EvidencePassed && *record.ExitCode != 0 {
			return errors.New("passed runtime_command evidence requires exit_code=0")
		}
	case model.EvidenceBrowser:
		if actor != "browser" {
			return errors.New("browser evidence must be recorded by actor=browser")
		}
		if record.Artifact == "" || record.ArtifactSHA == "" {
			return errors.New("browser evidence requires an artifact and sha256")
		}
	case model.EvidenceOwnerApproval:
		if actor != "owner" {
			return errors.New("owner_approval evidence must be recorded by actor=owner")
		}
	case model.EvidenceIndependentReview:
		if actor != "verifier" {
			return errors.New("independent_review evidence must be recorded by actor=verifier")
		}
	default:
		return fmt.Errorf("unsupported evidence kind %q", record.Kind)
	}
	return nil
}

func PassedCriterionIDs(contract model.MissionContract, evidence []model.EvidenceRecord) map[string]bool {
	results := EvaluateCriteria(contract, evidence)
	out := make(map[string]bool, len(results))
	for _, result := range results {
		out[result.Criterion.ID] = result.Passed
	}
	return out
}

func EvaluateCriteria(contract model.MissionContract, evidence []model.EvidenceRecord) []model.CriterionResult {
	byCriterion := make(map[string][]model.EvidenceRecord)
	for _, record := range evidence {
		if record.Status == model.EvidencePassed {
			byCriterion[record.CriterionID] = append(byCriterion[record.CriterionID], record)
		}
	}
	results := make([]model.CriterionResult, 0, len(contract.Criteria))
	for _, criterion := range contract.Criteria {
		available := make(map[model.EvidenceKind]bool)
		for _, record := range byCriterion[criterion.ID] {
			available[record.Kind] = true
		}
		var missing []model.EvidenceKind
		for _, required := range criterion.RequiredEvidence {
			if !available[required] {
				missing = append(missing, required)
			}
		}
		results = append(results, model.CriterionResult{
			Criterion: criterion,
			Passed:    len(missing) == 0,
			Missing:   missing,
			Evidence:  byCriterion[criterion.ID],
		})
	}
	return results
}

func Completion(contract model.MissionContract, state model.RunState, evidence []model.EvidenceRecord) model.CompletionReport {
	results := EvaluateCriteria(contract, evidence)
	report := model.CompletionReport{TotalCriteria: len(results), CriterionResults: results}
	for _, result := range results {
		if result.Passed {
			report.PassedCriteria++
		}
	}
	for _, finding := range state.Findings {
		if finding.Status == model.FindingOpen && (finding.Severity == model.SeverityP0 || finding.Severity == model.SeverityP1) {
			report.OpenBlockers = append(report.OpenBlockers, finding)
		}
	}
	sort.Slice(report.OpenBlockers, func(i, j int) bool { return report.OpenBlockers[i].Severity < report.OpenBlockers[j].Severity })
	report.Complete = report.PassedCriteria == report.TotalCriteria && report.TotalCriteria > 0 && len(report.OpenBlockers) == 0
	return report
}
