package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/aleka7sk/auto-company-safe/engine-v2/internal/model"
)

const StateDir = ".auto-company-v2"

func Root(projectRoot string) string { return filepath.Join(projectRoot, StateDir) }
func ContractPath(projectRoot string) string { return filepath.Join(Root(projectRoot), "contracts", "mission.json") }
func ConfigPath(projectRoot string) string { return filepath.Join(Root(projectRoot), "config.json") }
func StatePath(projectRoot string) string { return filepath.Join(Root(projectRoot), "state.json") }
func EvidenceDir(projectRoot string) string { return filepath.Join(Root(projectRoot), "evidence") }

func Ensure(projectRoot string) error {
	for _, path := range []string{filepath.Join(Root(projectRoot), "contracts"), EvidenceDir(projectRoot), filepath.Join(Root(projectRoot), "artifacts"), filepath.Join(Root(projectRoot), "worktrees")} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			return fmt.Errorf("create %s: %w", path, err)
		}
	}
	return nil
}

func SaveJSON(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return fmt.Errorf("encode %s: %w", path, err)
	}
	data = append(data, '\n')
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create parent for %s: %w", path, err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("write temp file: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("sync temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("replace %s: %w", path, err)
	}
	return nil
}

func LoadJSON(path string, target any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("%s does not exist; run init first", path)
		}
		return fmt.Errorf("read %s: %w", path, err)
	}
	if err := json.Unmarshal(data, target); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	return nil
}

func LoadContract(projectRoot string) (model.MissionContract, error) {
	var value model.MissionContract
	return value, LoadJSON(ContractPath(projectRoot), &value)
}

func LoadConfig(projectRoot string) (model.Config, error) {
	var value model.Config
	return value, LoadJSON(ConfigPath(projectRoot), &value)
}

func LoadState(projectRoot string) (model.RunState, error) {
	var value model.RunState
	return value, LoadJSON(StatePath(projectRoot), &value)
}

func LoadEvidence(projectRoot string) ([]model.EvidenceRecord, error) {
	entries, err := os.ReadDir(EvidenceDir(projectRoot))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("read evidence directory: %w", err)
	}
	var out []model.EvidenceRecord
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		var record model.EvidenceRecord
		if err := LoadJSON(filepath.Join(EvidenceDir(projectRoot), entry.Name()), &record); err != nil {
			return nil, err
		}
		out = append(out, record)
	}
	return out, nil
}
