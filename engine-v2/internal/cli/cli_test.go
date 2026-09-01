package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestInitAndStatusDoNotTrustCheckedMissionBoxes(t *testing.T) {
	root := t.TempDir()
	mission := `**Product:** Widget

## Problem
A problem.

## Definition of Done
- [x] [AC-BUILD] go build succeeds
`
	if err := os.WriteFile(filepath.Join(root, "MISSION.md"), []byte(mission), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "product"), 0o755); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	r := Runner{Out: &out, Err: &out, Now: func() time.Time { return time.Unix(1, 0) }}
	if err := r.Run([]string{"init", "--root", root, "--product-root", "product"}); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := r.Run([]string{"status", "--root", root}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "Criteria: 0/1") {
		t.Fatalf("checked mission box was trusted:\n%s", out.String())
	}
}

func TestRecordEvidenceRejectsModelActor(t *testing.T) {
	root := t.TempDir()
	mission := "**Product:** Widget\n\n## Definition of Done\n- [ ] [AC-BUILD] go build succeeds\n"
	if err := os.WriteFile(filepath.Join(root, "MISSION.md"), []byte(mission), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "product"), 0o755); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	r := Runner{Out: &out, Err: &out, Now: func() time.Time { return time.Unix(1, 0) }}
	if err := r.Run([]string{"init", "--root", root, "--product-root", "product"}); err != nil {
		t.Fatal(err)
	}
	err := r.Run([]string{"record-evidence", "--root", root, "--criterion", "AC-BUILD", "--kind", "runtime_command", "--actor", "model", "--command", "go build ./...", "--exit-code", "0"})
	if err == nil {
		t.Fatal("expected model evidence rejection")
	}
}
