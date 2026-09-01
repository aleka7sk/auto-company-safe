package model

import "time"

const SchemaVersion = "2.0"

type EvidenceKind string

const (
	EvidenceRuntimeCommand     EvidenceKind = "runtime_command"
	EvidenceBrowser            EvidenceKind = "browser"
	EvidenceOwnerApproval      EvidenceKind = "owner_approval"
	EvidenceIndependentReview EvidenceKind = "independent_review"
)

type EvidenceStatus string

const (
	EvidencePassed EvidenceStatus = "passed"
	EvidenceFailed EvidenceStatus = "failed"
)

type Criterion struct {
	ID               string         `json:"id"`
	Text             string         `json:"text"`
	RequiredEvidence []EvidenceKind `json:"required_evidence"`
	SourceLine       int            `json:"source_line"`
}

type MissionContract struct {
	SchemaVersion string      `json:"schema_version"`
	Product       string      `json:"product"`
	ProductSlug   string      `json:"product_slug"`
	MissionPath   string      `json:"mission_path"`
	MissionSHA256 string      `json:"mission_sha256"`
	Problem       string      `json:"problem,omitempty"`
	TargetUser    string      `json:"target_user,omitempty"`
	InScope       []string    `json:"in_scope,omitempty"`
	OutOfScope    []string    `json:"out_of_scope,omitempty"`
	Criteria      []Criterion `json:"criteria"`
	CompiledAt    time.Time   `json:"compiled_at"`
}

type Config struct {
	SchemaVersion          string  `json:"schema_version"`
	ProductRoot            string  `json:"product_root"`
	MaxCriteriaPerSlice    int     `json:"max_criteria_per_slice"`
	MaxChangedFiles        int     `json:"max_changed_files"`
	MaxChangedLines        int     `json:"max_changed_lines"`
	MaxAgentTurns          int     `json:"max_agent_turns"`
	MaxCycleBudgetUSD      float64 `json:"max_cycle_budget_usd"`
	MaxReviewFixCycles     int     `json:"max_review_fix_cycles"`
	RequireTrackedProduct  bool    `json:"require_tracked_product"`
	RequireBrowserForUI    bool    `json:"require_browser_for_ui"`
	RequireIndependentTest bool    `json:"require_independent_test"`
}

type SliceStatus string

const (
	SlicePlanned   SliceStatus = "planned"
	SliceBuilding  SliceStatus = "building"
	SliceVerifying SliceStatus = "verifying"
	SlicePassed    SliceStatus = "passed"
	SliceFailed    SliceStatus = "failed"
	SliceBlocked   SliceStatus = "blocked"
)

type Slice struct {
	ID           string      `json:"id"`
	CriterionIDs []string    `json:"criterion_ids"`
	Status       SliceStatus `json:"status"`
	Branch       string      `json:"branch,omitempty"`
	Worktree     string      `json:"worktree,omitempty"`
	BaseCommit   string      `json:"base_commit,omitempty"`
	HeadCommit   string      `json:"head_commit,omitempty"`
	CreatedAt    time.Time   `json:"created_at"`
	UpdatedAt    time.Time   `json:"updated_at"`
}

type FindingSeverity string

const (
	SeverityP0 FindingSeverity = "P0"
	SeverityP1 FindingSeverity = "P1"
	SeverityP2 FindingSeverity = "P2"
	SeverityP3 FindingSeverity = "P3"
)

type FindingStatus string

const (
	FindingOpen     FindingStatus = "open"
	FindingResolved FindingStatus = "resolved"
	FindingWaived   FindingStatus = "waived"
)

type Finding struct {
	ID           string          `json:"id"`
	Severity     FindingSeverity `json:"severity"`
	Title        string          `json:"title"`
	Description  string          `json:"description,omitempty"`
	Source       string          `json:"source"`
	CriterionIDs []string        `json:"criterion_ids,omitempty"`
	Status       FindingStatus   `json:"status"`
	CreatedAt    time.Time       `json:"created_at"`
	ResolvedAt   *time.Time      `json:"resolved_at,omitempty"`
	Resolution   string          `json:"resolution,omitempty"`
}

type EvidenceRecord struct {
	ID          string         `json:"id"`
	CriterionID string         `json:"criterion_id"`
	Kind        EvidenceKind   `json:"kind"`
	Actor       string         `json:"actor"`
	Status      EvidenceStatus `json:"status"`
	Command     string         `json:"command,omitempty"`
	ExitCode    *int           `json:"exit_code,omitempty"`
	Artifact    string         `json:"artifact,omitempty"`
	ArtifactSHA string         `json:"artifact_sha256,omitempty"`
	Commit      string         `json:"commit,omitempty"`
	Notes       string         `json:"notes,omitempty"`
	CreatedAt   time.Time      `json:"created_at"`
}

type RunState struct {
	SchemaVersion string     `json:"schema_version"`
	Product       string     `json:"product"`
	ProductSlug   string     `json:"product_slug"`
	ProductRoot   string     `json:"product_root"`
	MissionSHA256 string     `json:"mission_sha256"`
	Phase         string     `json:"phase"`
	Slices        []Slice    `json:"slices"`
	Findings      []Finding  `json:"findings"`
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
	CompletedAt   *time.Time `json:"completed_at,omitempty"`
}

type CriterionResult struct {
	Criterion Criterion        `json:"criterion"`
	Passed    bool             `json:"passed"`
	Missing   []EvidenceKind   `json:"missing_evidence,omitempty"`
	Evidence  []EvidenceRecord `json:"evidence,omitempty"`
}

type CompletionReport struct {
	Complete         bool              `json:"complete"`
	PassedCriteria   int               `json:"passed_criteria"`
	TotalCriteria    int               `json:"total_criteria"`
	OpenBlockers     []Finding         `json:"open_blockers,omitempty"`
	CriterionResults []CriterionResult `json:"criterion_results"`
}
