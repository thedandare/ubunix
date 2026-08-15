// Package defaultnix reads and writes the imports list in a default.nix file.
//
// It treats the file as line-oriented text, touching only lines inside the
// imports = [ ... ]; block.  Everything outside that block is preserved verbatim.
package defaultnix

import (
	"os"
	"path/filepath"
	"strings"
)

// Import represents one entry inside the imports = [ ... ]; list.
type Import struct {
	// Base is the filename without leading "./" (e.g. "pentesting.nix").
	Base string
	// Enabled is false when the line is commented out.
	Enabled bool
}

// State holds the parsed imports from a default.nix file.
type State struct {
	Path    string
	Imports []Import
}

// EnabledFor returns whether the file with the given base name is enabled.
func (s *State) EnabledFor(base string) (bool, bool) {
	if s == nil {
		return false, false
	}
	for _, imp := range s.Imports {
		if imp.Base == base {
			return imp.Enabled, true
		}
	}
	return false, false
}

// Find locates a default.nix in the same directory as any of the given paths.
// Returns empty string if not found.
func Find(paths []string) string {
	seen := map[string]bool{}
	for _, p := range paths {
		dir := p
		if !isDir(p) {
			dir = filepath.Dir(p)
		}
		if seen[dir] {
			continue
		}
		seen[dir] = true
		candidate := filepath.Join(dir, "default.nix")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return ""
}

// Parse reads the default.nix at path and returns the imports list.
func Parse(path string) (*State, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
	s := &State{Path: path}
	inside := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if !inside {
			if strings.Contains(trimmed, "imports") && strings.Contains(trimmed, "[") {
				inside = true
			}
			continue
		}
		if strings.HasPrefix(trimmed, "]") {
			break
		}
		enabled := true
		content := trimmed
		if strings.HasPrefix(content, "#") {
			enabled = false
			content = strings.TrimSpace(strings.TrimPrefix(content, "#"))
		}
		content = strings.TrimSpace(content)
		if !strings.HasPrefix(content, "./") {
			continue
		}
		base := filepath.Base(strings.TrimPrefix(content, "./"))
		if base == "" || base == "." {
			continue
		}
		s.Imports = append(s.Imports, Import{Base: base, Enabled: enabled})
	}
	return s, nil
}

// SetEnabled rewrites the default.nix file toggling the import for base.
// base is the filename, e.g. "pentesting.nix".
func SetEnabled(path, base string, enabled bool) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
	inside := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if !inside {
			if strings.Contains(trimmed, "imports") && strings.Contains(trimmed, "[") {
				inside = true
			}
			continue
		}
		if strings.HasPrefix(trimmed, "]") {
			break
		}
		content := trimmed
		wasEnabled := true
		if strings.HasPrefix(content, "#") {
			wasEnabled = false
			content = strings.TrimSpace(strings.TrimPrefix(content, "#"))
		}
		if !strings.HasPrefix(content, "./") {
			continue
		}
		lineBase := filepath.Base(strings.TrimPrefix(content, "./"))
		if lineBase != base {
			continue
		}
		indent := leadingWhitespace(line)
		if enabled && !wasEnabled {
			lines[i] = indent + content
		} else if !enabled && wasEnabled {
			lines[i] = indent + "# " + content
		}
		break
	}
	out := strings.Join(lines, "\n")
	return os.WriteFile(path, []byte(out), 0o644)
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func leadingWhitespace(s string) string {
	for i, r := range s {
		if r != ' ' && r != '\t' {
			return s[:i]
		}
	}
	return s
}
