// Package gitctl wraps the local git executable.
//
// TUINIX does not use a Go Git library on purpose.  Shelling out keeps behavior
// identical to the Git CLI the user already knows, and it avoids extra CGO or
// module dependencies on NixOS.
package gitctl

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func IsRepo(dir string) bool {
	cmd := exec.Command("git", "-C", dir, "rev-parse", "--is-inside-work-tree")
	return cmd.Run() == nil
}

func Init(dir string) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	out := &bytes.Buffer{}
	cmds := [][]string{
		{"git", "-C", dir, "init"},
	}
	for _, args := range cmds {
		cmd := exec.Command(args[0], args[1:]...)
		cmd.Stdout = out
		cmd.Stderr = out
		if err := cmd.Run(); err != nil {
			return out.String(), err
		}
	}
	_ = ensureGitignore(dir)
	return out.String(), nil
}

func ensureGitignore(dir string) error {
	path := filepath.Join(dir, ".gitignore")
	content := "*.bak\n*.bak.*\n*.tuinix.tmp\n.tuinix/\n"
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return os.WriteFile(path, []byte(content), 0o644)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	s := string(b)
	changed := false
	for _, line := range strings.Split(strings.TrimSpace(content), "\n") {
		if !strings.Contains(s, line) {
			s += "\n" + line
			changed = true
		}
	}
	if changed {
		return os.WriteFile(path, []byte(s), 0o644)
	}
	return nil
}

func CommitAll(dir, message string) (string, error) {
	if strings.TrimSpace(message) == "" {
		message = "tuinix: update packages"
	}
	out := &bytes.Buffer{}
	for _, args := range [][]string{
		{"git", "-C", dir, "add", "-A"},
		{"git", "-C", dir, "commit", "-m", message},
	} {
		cmd := exec.Command(args[0], args[1:]...)
		cmd.Stdout = out
		cmd.Stderr = out
		if err := cmd.Run(); err != nil {
			return out.String(), err
		}
	}
	return out.String(), nil
}

func Status(dir string) string {
	cmd := exec.Command("git", "-C", dir, "status", "--short")
	b, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Sprintf("git status failed: %v\n%s", err, string(b))
	}
	if strings.TrimSpace(string(b)) == "" {
		return "git status: clean"
	}
	return string(b)
}

func Log(dir string) string {
	cmd := exec.Command("git", "-C", dir, "log", "--oneline", "-5")
	b, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Sprintf("git log failed: %v\n%s", err, string(b))
	}
	return string(b)
}
