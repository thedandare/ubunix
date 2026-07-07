// Package save writes a mutated workspace back to disk.
//
// It is intentionally separate from parser/model because saving is the highest
// risk operation: it touches user files.  Keeping it isolated makes it easier to
// audit.  Think of it like a Dart repository/service class responsible for one
// external side effect.
package save

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"tuinix/internal/model"
)

// SaveAll writes every changed file in the workspace.
//
// Each changed file receives two safety backups:
//
//	file.nix.bak                  latest backup
//	file.nix.bak.YYYYMMDD-HHMMSS  timestamped backup
func SaveAll(w *model.Workspace) error {
	if w == nil {
		return fmt.Errorf("nil workspace")
	}
	for _, f := range w.Files {
		if err := saveOne(w, f); err != nil {
			return err
		}
	}
	return nil
}

func saveOne(w *model.Workspace, f *model.NixFile) error {
	if f == nil {
		return nil
	}

	replacements := map[int]string{}
	removeLines := map[int]bool{}
	insertions := []*model.PackageEntry{}
	categoryInsertions := []*model.CategoryEntry{}
	sectionReplacements := map[int]string{}

	for _, p := range w.Packages {
		if p == nil {
			continue
		}
		if p.OriginalFile == f.Path && p.SectionLine >= 0 && p.Section != p.OriginalSection {
			sectionReplacements[p.SectionLine] = renderSectionLine(p)
		}
		// Existing package originally lived in this file.
		if p.OriginalFile == f.Path && p.Line >= 0 {
			if p.Removed || p.TargetFile != p.OriginalFile {
				removeLines[p.Line] = true
				continue
			}
			replacements[p.Line] = p.RenderLine()
		}
		// New package or moved-in package should be inserted in this file.
		if p.TargetFile == f.Path && (p.Added || p.OriginalFile != f.Path) && !p.Removed {
			insertions = append(insertions, p)
		}
	}

	for line, repl := range sectionReplacements {
		replacements[line] = repl
	}
	for _, c := range w.Categories {
		if c != nil && c.File == f.Path && c.Added {
			categoryInsertions = append(categoryInsertions, c)
		}
	}

	if len(replacements) == 0 && len(removeLines) == 0 && len(insertions) == 0 && len(categoryInsertions) == 0 {
		return nil
	}

	newLines := renderFileLines(f, replacements, removeLines, insertions, categoryInsertions)
	newContent := strings.Join(newLines, "\n")

	oldBytes, err := os.ReadFile(f.Path)
	if err != nil {
		return err
	}
	if string(oldBytes) == newContent {
		return nil
	}

	if err := createBackups(f.Path, oldBytes); err != nil {
		return err
	}

	tmp := f.Path + ".tuinix.tmp"
	if err := os.WriteFile(tmp, []byte(newContent), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, f.Path)
}

func renderSectionLine(p *model.PackageEntry) string {
	indent := p.SectionIndent
	if indent == "" {
		indent = "    "
	}
	return indent + "# " + strings.TrimSpace(p.Section)
}

func renderCategoryLine(c *model.CategoryEntry) string {
	indent := c.Indent
	if indent == "" {
		indent = "    "
	}
	return indent + "# " + strings.TrimSpace(c.Name)
}

func renderFileLines(f *model.NixFile, replacements map[int]string, removeLines map[int]bool, insertions []*model.PackageEntry, categoryInsertions []*model.CategoryEntry) []string {
	out := make([]string, 0, len(f.Lines)+len(insertions)+len(categoryInsertions)+8)

	// If the file has no recognized systemPackages block, append a simple block.
	// This is rare but useful when adding to a new empty package file.
	if f.PackageBlockEnd < 0 {
		out = append(out, f.Lines...)
		if len(out) > 0 && strings.TrimSpace(out[len(out)-1]) != "" {
			out = append(out, "")
		}
		out = append(out, "{ pkgs, ... }:", "{", "  environment.systemPackages = with pkgs; [")
		for _, c := range categoryInsertions {
			out = append(out, renderCategoryLine(c))
		}
		for _, p := range insertions {
			out = append(out, p.RenderLine())
		}
		out = append(out, "  ];", "}")
		return out
	}

	for i, line := range f.Lines {
		if i == f.PackageBlockEnd {
			if len(insertions) > 0 || len(categoryInsertions) > 0 {
				out = append(out, "")
				for _, c := range categoryInsertions {
					out = append(out, renderCategoryLine(c))
				}
				if len(insertions) > 0 {
					appendGroupedInsertions(&out, insertions)
				}
			}
		}
		if removeLines[i] {
			continue
		}
		if repl, ok := replacements[i]; ok {
			out = append(out, repl)
			continue
		}
		out = append(out, line)
	}
	return out
}

func appendGroupedInsertions(out *[]string, insertions []*model.PackageEntry) {
	lastSection := ""
	for _, p := range insertions {
		section := strings.TrimSpace(p.Section)
		if section == "" {
			section = "TUINIX Added / Moved"
		}
		if section != lastSection {
			*out = append(*out, "    # "+section)
			lastSection = section
		}
		*out = append(*out, p.RenderLine())
	}
}

func createBackups(path string, data []byte) error {
	if err := os.WriteFile(path+".bak", data, 0o644); err != nil {
		return err
	}
	suffix := time.Now().Format("20060102-150405")
	return os.WriteFile(path+".bak."+suffix, data, 0o644)
}

// WorkspaceDirectory returns the directory the user probably wants to version.
func WorkspaceDirectory(w *model.Workspace) string {
	if w == nil || w.Root == "" {
		cwd, _ := os.Getwd()
		return cwd
	}
	abs, err := filepath.Abs(w.Root)
	if err != nil {
		return w.Root
	}
	return abs
}
