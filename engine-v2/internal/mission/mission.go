package mission

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/aleka7sk/auto-company-safe/engine-v2/internal/model"
)

var explicitID = regexp.MustCompile(`^\[([A-Z][A-Z0-9-]{2,})\]\s+(.+)$`)

func Compile(path string, now time.Time) (model.MissionContract, error) {
	var contract model.MissionContract
	data, err := os.ReadFile(path)
	if err != nil {
		return contract, fmt.Errorf("read mission: %w", err)
	}
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	product := parseProduct(text)
	if product == "" || strings.EqualFold(product, "TBD") {
		return contract, errors.New("MISSION.md must contain a non-TBD '**Product:**' line")
	}

	sections := parseSections(text)
	criteria, err := parseCriteria(text)
	if err != nil {
		return contract, err
	}
	if len(criteria) == 0 {
		return contract, errors.New("MISSION.md Definition of Done has no checklist criteria")
	}

	digest := sha256.Sum256(data)
	abs, err := filepath.Abs(path)
	if err != nil {
		return contract, fmt.Errorf("resolve mission path: %w", err)
	}

	contract = model.MissionContract{
		SchemaVersion: model.SchemaVersion,
		Product:       product,
		ProductSlug:   slugify(product),
		MissionPath:   abs,
		MissionSHA256: hex.EncodeToString(digest[:]),
		Problem:       strings.TrimSpace(sections["Problem"]),
		TargetUser:    strings.TrimSpace(sections["Target User"]),
		InScope:       bullets(sections["In Scope"]),
		OutOfScope:    bullets(sections["Out of Scope"]),
		Criteria:      criteria,
		CompiledAt:    now.UTC(),
	}
	return contract, nil
}

func parseProduct(text string) string {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "**Product:**") {
			return strings.TrimSpace(strings.TrimPrefix(line, "**Product:**"))
		}
	}
	return ""
}

func parseSections(text string) map[string]string {
	sections := make(map[string]string)
	current := ""
	var body []string
	flush := func() {
		if current != "" {
			sections[current] = strings.TrimSpace(strings.Join(body, "\n"))
		}
		body = nil
	}
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "## ") {
			flush()
			current = strings.TrimSpace(strings.TrimPrefix(line, "## "))
			continue
		}
		if current != "" {
			body = append(body, line)
		}
	}
	flush()
	return sections
}

func parseCriteria(text string) ([]model.Criterion, error) {
	scanner := bufio.NewScanner(strings.NewReader(text))
	inDoD := false
	lineNo := 0
	seen := make(map[string]struct{})
	var out []model.Criterion
	for scanner.Scan() {
		lineNo++
		line := strings.TrimSpace(scanner.Text())
		if line == "## Definition of Done" {
			inDoD = true
			continue
		}
		if inDoD && strings.HasPrefix(line, "## ") {
			break
		}
		if !inDoD || !(strings.HasPrefix(line, "- [ ] ") || strings.HasPrefix(line, "- [x] ") || strings.HasPrefix(line, "- [X] ")) {
			continue
		}
		text := strings.TrimSpace(line[6:])
		id := ""
		if matches := explicitID.FindStringSubmatch(text); len(matches) == 3 {
			id, text = matches[1], strings.TrimSpace(matches[2])
		} else {
			h := sha256.Sum256([]byte(strings.ToLower(strings.Join(strings.Fields(text), " "))))
			id = "AC-" + strings.ToUpper(hex.EncodeToString(h[:5]))
		}
		if _, ok := seen[id]; ok {
			return nil, fmt.Errorf("duplicate criterion id %s", id)
		}
		seen[id] = struct{}{}
		out = append(out, model.Criterion{
			ID:               id,
			Text:             text,
			RequiredEvidence: inferEvidence(text),
			SourceLine:       lineNo,
		})
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan mission: %w", err)
	}
	if !inDoD {
		return nil, errors.New("MISSION.md is missing '## Definition of Done'")
	}
	return out, nil
}

func inferEvidence(text string) []model.EvidenceKind {
	lower := strings.ToLower(text)
	if strings.Contains(lower, "human") || strings.Contains(lower, "owner approval") || strings.Contains(lower, "manual review") {
		return []model.EvidenceKind{model.EvidenceOwnerApproval}
	}
	if strings.Contains(lower, "browser") || strings.Contains(lower, "responsive") || strings.Contains(lower, "screen") || strings.Contains(lower, "mobile") || strings.Contains(lower, "ui ") || strings.Contains(lower, "frontend") {
		return []model.EvidenceKind{model.EvidenceRuntimeCommand, model.EvidenceBrowser, model.EvidenceIndependentReview}
	}
	return []model.EvidenceKind{model.EvidenceRuntimeCommand, model.EvidenceIndependentReview}
}

func bullets(body string) []string {
	var out []string
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "- ") {
			out = append(out, strings.TrimSpace(strings.TrimPrefix(line, "- ")))
		}
	}
	return out
}

func slugify(value string) string {
	value = strings.ToLower(value)
	var b strings.Builder
	lastDash := false
	for _, r := range value {
		isASCIIAlphaNum := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		if isASCIIAlphaNum {
			b.WriteRune(r)
			lastDash = false
			continue
		}
		if !lastDash && b.Len() > 0 {
			b.WriteByte('-')
			lastDash = true
		}
	}
	return strings.Trim(b.String(), "-")
}
