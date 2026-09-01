package cli

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aleka7sk/auto-company-safe/engine-v2/internal/mission"
	"github.com/aleka7sk/auto-company-safe/engine-v2/internal/model"
	"github.com/aleka7sk/auto-company-safe/engine-v2/internal/policy"
	"github.com/aleka7sk/auto-company-safe/engine-v2/internal/store"
)

const version = "2.0.0-alpha.1"

type Runner struct {
	Out io.Writer
	Err io.Writer
	Now func() time.Time
}

func New() Runner { return Runner{Out: os.Stdout, Err: os.Stderr, Now: time.Now} }

func (r Runner) Run(args []string) error {
	if len(args) == 0 {
		r.usage()
		return nil
	}
	switch args[0] {
	case "version":
		fmt.Fprintln(r.Out, version)
		return nil
	case "init":
		return r.init(args[1:])
	case "status":
		return r.status(args[1:])
	case "next-slice":
		return r.nextSlice(args[1:])
	case "record-evidence":
		return r.recordEvidence(args[1:])
	case "add-finding":
		return r.addFinding(args[1:])
	case "resolve-finding":
		return r.resolveFinding(args[1:])
	case "complete":
		return r.complete(args[1:])
	case "doctor":
		return r.doctor(args[1:])
	case "export-context":
		return r.exportContext(args[1:])
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func (r Runner) usage() {
	fmt.Fprintln(r.Out, `Auto Company Engine v2

Commands:
  init              compile MISSION.md into immutable structured contracts
  doctor            verify repository, product tracking, tools and state
  next-slice        create a bounded slice of at most N pending criteria
  record-evidence   add runtime/browser/owner/verifier evidence
  add-finding       add an independent P0-P3 finding
  resolve-finding   resolve or waive a finding
  status            show computed progress; ignores model-authored checkboxes
  complete          exit 0 only when runtime evidence proves completion
  export-context    emit a compact prompt packet for one stage or slice
  version           print the runtime version`)
}

func rootFlag(fs *flag.FlagSet) *string {
	return fs.String("root", ".", "Auto Company repository root")
}

func (r Runner) init(args []string) error {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	fs.SetOutput(r.Err)
	root := rootFlag(fs)
	missionPath := fs.String("mission", "MISSION.md", "mission file relative to root")
	productRoot := fs.String("product-root", "", "product repository/directory; defaults to projects/<slug>")
	force := fs.Bool("force", false, "replace an existing v2 state")
	if err := fs.Parse(args); err != nil {
		return err
	}
	absRoot, err := filepath.Abs(*root)
	if err != nil {
		return err
	}
	if _, err := os.Stat(store.StatePath(absRoot)); err == nil && !*force {
		return errors.New("v2 state already exists; use --force only after reviewing existing evidence")
	}
	contract, err := mission.Compile(filepath.Join(absRoot, *missionPath), r.Now())
	if err != nil {
		return err
	}
	if *productRoot == "" {
		*productRoot = filepath.Join("projects", contract.ProductSlug)
	}
	config := policy.DefaultConfig(*productRoot)
	state := model.RunState{
		SchemaVersion: model.SchemaVersion,
		Product:       contract.Product,
		ProductSlug:   contract.ProductSlug,
		ProductRoot:   *productRoot,
		MissionSHA256: contract.MissionSHA256,
		Phase:         "discovery",
		CreatedAt:     r.Now().UTC(),
		UpdatedAt:     r.Now().UTC(),
	}
	if err := store.Ensure(absRoot); err != nil {
		return err
	}
	if err := store.SaveJSON(store.ContractPath(absRoot), contract); err != nil {
		return err
	}
	if err := store.SaveJSON(store.ConfigPath(absRoot), config); err != nil {
		return err
	}
	if err := store.SaveJSON(store.StatePath(absRoot), state); err != nil {
		return err
	}
	fmt.Fprintf(r.Out, "Initialized Engine v2 for %s with %d criteria.\n", contract.Product, len(contract.Criteria))
	fmt.Fprintf(r.Out, "State: %s\n", store.Root(absRoot))
	return nil
}

func (r Runner) status(args []string) error {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(r.Err)
	root := rootFlag(fs)
	asJSON := fs.Bool("json", false, "print JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	abs, _ := filepath.Abs(*root)
	contract, state, evidence, err := loadAll(abs)
	if err != nil {
		return err
	}
	report := policy.Completion(contract, state, evidence)
	if *asJSON {
		return writeJSON(r.Out, report)
	}
	fmt.Fprintf(r.Out, "Product: %s\nPhase: %s\nCriteria: %d/%d\nOpen P0/P1: %d\nComplete: %t\n", state.Product, state.Phase, report.PassedCriteria, report.TotalCriteria, len(report.OpenBlockers), report.Complete)
	for _, result := range report.CriterionResults {
		mark := "[ ]"
		if result.Passed {
			mark = "[x]"
		}
		fmt.Fprintf(r.Out, "%s %s %s", mark, result.Criterion.ID, result.Criterion.Text)
		if len(result.Missing) > 0 {
			fmt.Fprintf(r.Out, " (missing: %s)", joinKinds(result.Missing))
		}
		fmt.Fprintln(r.Out)
	}
	return nil
}

func (r Runner) nextSlice(args []string) error {
	fs := flag.NewFlagSet("next-slice", flag.ContinueOnError)
	fs.SetOutput(r.Err)
	root := rootFlag(fs)
	max := fs.Int("max-criteria", 0, "override configured slice size")
	if err := fs.Parse(args); err != nil {
		return err
	}
	abs, _ := filepath.Abs(*root)
	contract, state, evidence, err := loadAll(abs)
	if err != nil {
		return err
	}
	config, err := store.LoadConfig(abs)
	if err != nil {
		return err
	}
	limit := config.MaxCriteriaPerSlice
	if *max > 0 {
		limit = *max
	}
	if limit > config.MaxCriteriaPerSlice {
		return fmt.Errorf("requested %d criteria exceeds configured maximum %d", limit, config.MaxCriteriaPerSlice)
	}
	slice, err := policy.SelectSlice(contract, state, evidence, limit, r.Now())
	if err != nil {
		return err
	}
	state.Slices = append(state.Slices, slice)
	state.Phase = "slice_planning"
	state.UpdatedAt = r.Now().UTC()
	if err := store.SaveJSON(store.StatePath(abs), state); err != nil {
		return err
	}
	return writeJSON(r.Out, slice)
}

func (r Runner) recordEvidence(args []string) error {
	fs := flag.NewFlagSet("record-evidence", flag.ContinueOnError)
	fs.SetOutput(r.Err)
	root := rootFlag(fs)
	criterion := fs.String("criterion", "", "criterion id")
	kind := fs.String("kind", "", "runtime_command|browser|owner_approval|independent_review")
	actor := fs.String("actor", "", "runtime|browser|owner|verifier")
	status := fs.String("status", "passed", "passed|failed")
	command := fs.String("command", "", "executed command")
	exitCodeText := fs.String("exit-code", "", "command exit code")
	artifact := fs.String("artifact", "", "evidence artifact path")
	commit := fs.String("commit", "", "git commit under test")
	notes := fs.String("notes", "", "short evidence notes")
	if err := fs.Parse(args); err != nil {
		return err
	}
	abs, _ := filepath.Abs(*root)
	contract, _, _, err := loadAll(abs)
	if err != nil {
		return err
	}
	if !criterionExists(contract, *criterion) {
		return fmt.Errorf("unknown criterion %q", *criterion)
	}
	record := model.EvidenceRecord{
		CriterionID: *criterion, Kind: model.EvidenceKind(*kind), Actor: *actor,
		Status: model.EvidenceStatus(*status), Command: *command, Artifact: *artifact,
		Commit: *commit, Notes: *notes, CreatedAt: r.Now().UTC(),
	}
	if *exitCodeText != "" {
		value, err := strconv.Atoi(*exitCodeText)
		if err != nil {
			return fmt.Errorf("parse exit code: %w", err)
		}
		record.ExitCode = &value
	}
	if *artifact != "" {
		digest, err := hashFile(filepath.Join(abs, *artifact))
		if err != nil {
			return err
		}
		record.ArtifactSHA = digest
	}
	record.ID = evidenceID(record)
	if err := policy.ValidateEvidence(record); err != nil {
		return err
	}
	if err := store.SaveJSON(filepath.Join(store.EvidenceDir(abs), record.ID+".json"), record); err != nil {
		return err
	}
	return writeJSON(r.Out, record)
}

func (r Runner) addFinding(args []string) error {
	fs := flag.NewFlagSet("add-finding", flag.ContinueOnError)
	fs.SetOutput(r.Err)
	root := rootFlag(fs)
	severity := fs.String("severity", "", "P0|P1|P2|P3")
	title := fs.String("title", "", "finding title")
	description := fs.String("description", "", "details")
	source := fs.String("source", "independent_review", "finding source")
	criteria := fs.String("criteria", "", "comma-separated criterion ids")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *title == "" {
		return errors.New("finding title is required")
	}
	abs, _ := filepath.Abs(*root)
	contract, state, _, err := loadAll(abs)
	if err != nil {
		return err
	}
	sev := model.FindingSeverity(strings.ToUpper(*severity))
	if sev != model.SeverityP0 && sev != model.SeverityP1 && sev != model.SeverityP2 && sev != model.SeverityP3 {
		return fmt.Errorf("invalid severity %q", *severity)
	}
	ids := splitCSV(*criteria)
	for _, id := range ids {
		if !criterionExists(contract, id) {
			return fmt.Errorf("unknown criterion %q", id)
		}
	}
	finding := model.Finding{ID: fmt.Sprintf("F-%03d", len(state.Findings)+1), Severity: sev, Title: *title, Description: *description, Source: *source, CriterionIDs: ids, Status: model.FindingOpen, CreatedAt: r.Now().UTC()}
	state.Findings = append(state.Findings, finding)
	state.UpdatedAt = r.Now().UTC()
	if err := store.SaveJSON(store.StatePath(abs), state); err != nil {
		return err
	}
	return writeJSON(r.Out, finding)
}

func (r Runner) resolveFinding(args []string) error {
	fs := flag.NewFlagSet("resolve-finding", flag.ContinueOnError)
	fs.SetOutput(r.Err)
	root := rootFlag(fs)
	id := fs.String("id", "", "finding id")
	resolution := fs.String("resolution", "", "resolution evidence")
	waive := fs.Bool("waive", false, "waive rather than resolve")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *id == "" || *resolution == "" {
		return errors.New("id and resolution are required")
	}
	abs, _ := filepath.Abs(*root)
	_, state, _, err := loadAll(abs)
	if err != nil {
		return err
	}
	found := false
	now := r.Now().UTC()
	for i := range state.Findings {
		if state.Findings[i].ID == *id {
			found = true
			if *waive {
				state.Findings[i].Status = model.FindingWaived
			} else {
				state.Findings[i].Status = model.FindingResolved
			}
			state.Findings[i].ResolvedAt = &now
			state.Findings[i].Resolution = *resolution
		}
	}
	if !found {
		return fmt.Errorf("finding %q not found", *id)
	}
	state.UpdatedAt = now
	return store.SaveJSON(store.StatePath(abs), state)
}

func (r Runner) complete(args []string) error {
	fs := flag.NewFlagSet("complete", flag.ContinueOnError)
	fs.SetOutput(r.Err)
	root := rootFlag(fs)
	asJSON := fs.Bool("json", false, "print JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	abs, _ := filepath.Abs(*root)
	contract, state, evidence, err := loadAll(abs)
	if err != nil {
		return err
	}
	report := policy.Completion(contract, state, evidence)
	if *asJSON {
		_ = writeJSON(r.Out, report)
	} else {
		fmt.Fprintf(r.Out, "Complete=%t criteria=%d/%d blockers=%d\n", report.Complete, report.PassedCriteria, report.TotalCriteria, len(report.OpenBlockers))
	}
	if !report.Complete {
		return errors.New("completion gate failed")
	}
	now := r.Now().UTC()
	state.Phase = "complete"
	state.CompletedAt = &now
	state.UpdatedAt = now
	return store.SaveJSON(store.StatePath(abs), state)
}

func (r Runner) doctor(args []string) error {
	fs := flag.NewFlagSet("doctor", flag.ContinueOnError)
	fs.SetOutput(r.Err)
	root := rootFlag(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	abs, _ := filepath.Abs(*root)
	contract, state, _, err := loadAll(abs)
	if err != nil {
		return err
	}
	checks := []struct {
		name string
		err  error
	}{
		{"mission hash", verifyMissionHash(contract)},
		{"git", commandAvailable("git")},
		{"claude", commandAvailable("claude")},
		{"jq", commandAvailable("jq")},
		{"product tracking", verifyProductTracking(abs, state.ProductRoot)},
	}
	failed := 0
	for _, check := range checks {
		if check.err != nil {
			failed++
			fmt.Fprintf(r.Out, "FAIL %-20s %v\n", check.name, check.err)
		} else {
			fmt.Fprintf(r.Out, "PASS %s\n", check.name)
		}
	}
	if failed > 0 {
		return fmt.Errorf("doctor found %d problem(s)", failed)
	}
	return nil
}

func (r Runner) exportContext(args []string) error {
	fs := flag.NewFlagSet("export-context", flag.ContinueOnError)
	fs.SetOutput(r.Err)
	root := rootFlag(fs)
	stage := fs.String("stage", "implementation", "discovery|architecture|implementation|adversarial_test|verification")
	sliceID := fs.String("slice", "", "slice id; defaults to latest")
	if err := fs.Parse(args); err != nil {
		return err
	}
	abs, _ := filepath.Abs(*root)
	contract, state, evidence, err := loadAll(abs)
	if err != nil {
		return err
	}
	var selected *model.Slice
	if *sliceID != "" {
		for i := range state.Slices {
			if state.Slices[i].ID == *sliceID {
				selected = &state.Slices[i]
			}
		}
	} else if len(state.Slices) > 0 {
		selected = &state.Slices[len(state.Slices)-1]
	}
	fmt.Fprintf(r.Out, "# Auto Company Engine v2 context\n\nStage: %s\nProduct: %s\nProduct root: %s\nMission SHA-256: %s\n\n", *stage, contract.Product, state.ProductRoot, contract.MissionSHA256)
	fmt.Fprint(r.Out, "## Operating contract\n- Treat requirements as hypotheses to understand, not prose to obey blindly.\n- Preserve the product problem and explicit boundaries. Challenge ambiguous or harmful implementation choices.\n- For material decisions, research current primary sources, compare at least three realistic options, include evidence against the preferred option, and record trade-offs.\n- Improvements are allowed only when they strengthen the stated user outcome without adding a second product, external-account dependency, sensitive-data class, pricing commitment, or irreversible architecture. Otherwise propose the change for owner approval.\n- The implementation model cannot certify completion. Runtime, browser, owner, and independent verifier evidence are separate.\n- Do not edit MISSION.md or generated contracts.\n\n")
	if selected != nil {
		fmt.Fprintf(r.Out, "## Active slice\nID: %s\nCriteria:\n", selected.ID)
		for _, id := range selected.CriterionIDs {
			if c, ok := criterionByID(contract, id); ok {
				fmt.Fprintf(r.Out, "- %s: %s\n", c.ID, c.Text)
			}
		}
	} else {
		fmt.Fprintln(r.Out, "## Active slice\nNo slice selected. Discovery and architecture may proceed read-only.")
	}
	report := policy.Completion(contract, state, evidence)
	fmt.Fprintf(r.Out, "\n## Current evidence\n%d/%d criteria proven; %d open P0/P1 findings.\n", report.PassedCriteria, report.TotalCriteria, len(report.OpenBlockers))
	return nil
}

func loadAll(root string) (model.MissionContract, model.RunState, []model.EvidenceRecord, error) {
	contract, err := store.LoadContract(root)
	if err != nil {
		return contract, model.RunState{}, nil, err
	}
	state, err := store.LoadState(root)
	if err != nil {
		return contract, state, nil, err
	}
	evidence, err := store.LoadEvidence(root)
	return contract, state, evidence, err
}
func writeJSON(w io.Writer, value any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(value)
}
func joinKinds(values []model.EvidenceKind) string {
	parts := make([]string, len(values))
	for i, v := range values {
		parts[i] = string(v)
	}
	return strings.Join(parts, ",")
}
func criterionExists(contract model.MissionContract, id string) bool {
	_, ok := criterionByID(contract, id)
	return ok
}
func criterionByID(contract model.MissionContract, id string) (model.Criterion, bool) {
	for _, c := range contract.Criteria {
		if c.ID == id {
			return c, true
		}
	}
	return model.Criterion{}, false
}
func splitCSV(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
func evidenceID(record model.EvidenceRecord) string {
	h := sha256.Sum256([]byte(fmt.Sprintf("%s|%s|%s|%s|%s", record.CriterionID, record.Kind, record.Actor, record.CreatedAt.Format(time.RFC3339Nano), record.Command)))
	return "E-" + strings.ToUpper(hex.EncodeToString(h[:6]))
}
func hashFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read artifact %s: %w", path, err)
	}
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:]), nil
}
func verifyMissionHash(contract model.MissionContract) error {
	data, err := os.ReadFile(contract.MissionPath)
	if err != nil {
		return err
	}
	h := sha256.Sum256(data)
	got := hex.EncodeToString(h[:])
	if got != contract.MissionSHA256 {
		return errors.New("MISSION.md changed after compilation; recompile only after owner review")
	}
	return nil
}
func commandAvailable(name string) error { _, err := exec.LookPath(name); return err }
func verifyProductTracking(root, productRoot string) error {
	abs := productRoot
	if !filepath.IsAbs(abs) {
		abs = filepath.Join(root, productRoot)
	}
	if _, err := os.Stat(abs); err != nil {
		return fmt.Errorf("product root unavailable: %w", err)
	}
	if _, err := os.Stat(filepath.Join(abs, ".git")); err == nil {
		return nil
	}
	cmd := exec.Command("git", "-C", root, "check-ignore", "-q", productRoot)
	if err := cmd.Run(); err == nil {
		return errors.New("product root is ignored and is not an independent git repository")
	}
	cmd = exec.Command("git", "-C", root, "ls-files", "--error-unmatch", productRoot)
	if err := cmd.Run(); err != nil {
		return errors.New("product root is not tracked; initialize a nested repository or add it to the parent repository")
	}
	return nil
}

func sortedKeys[K ~string, V any](m map[K]V) []K {
	keys := make([]K, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	return keys
}
