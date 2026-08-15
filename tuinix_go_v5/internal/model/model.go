// Package model contains the data structures that describe TUINIX's world.
//
// A useful Dart analogy:
//   - A Go package is similar to a Dart library directory.
//   - Exported identifiers start with an uppercase letter.  PackageEntry is
//     public to other Go packages; packageEntry would be private.
//   - Structs are Go's closest match to simple Dart classes with fields.
//   - Methods are declared separately with a receiver: func (w *Workspace) Save().
//
// This package deliberately has no Bubble Tea, terminal, Git, or filesystem
// rendering logic.  It is the application's domain model.
package model

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

// PackageEntry represents one package-like item found in, or added to, an
// environment.systemPackages list.
//
// The same struct tracks both the original file location and the current target
// file location.  This makes moving a package cheap: changing TargetFile is
// enough.  The save layer later interprets this as "remove original line from
// OriginalFile and insert rendered package line in TargetFile".
type PackageEntry struct {
	// ID is stable while the program is running.  It is not written to disk.
	ID string

	// Attr is the Nix attribute path, for example:
	//   dnsx
	//   dnscrypt-proxy
	//   gnomeExtensions.sanad
	//   gnuradioPackages.osmosdr
	Attr string
	// OriginalAttr is used to detect renames.
	OriginalAttr string

	// Meta is the trailing comment after the package name, without the leading #.
	// Example line:
	//   # dnsx # Fast DNS toolkit
	// has Meta == "Fast DNS toolkit".
	Meta string
	// OriginalMeta is used to detect comment edits.
	OriginalMeta string

	// DocMarkdown is an optional block comment immediately below the package,
	// written as /* markdown */ in the source file.
	DocMarkdown string

	// Section is a human label inferred from nearby comments.  It improves the UI
	// but is not required for saving.
	Section string
	// OriginalSection is used to detect category renames.
	OriginalSection string

	// SectionLine is the zero-based line number of the comment that introduced
	// Section, when one exists.
	SectionLine   int
	SectionIndent string

	// OriginalFile is the path where this package came from.  For added packages,
	// OriginalFile is empty because the package did not exist on disk yet.
	OriginalFile string

	// TargetFile is where the package should be written on the next save.
	TargetFile string

	// Line is the zero-based line number in the original file.  Added packages use
	// Line == -1.  Keeping the original line lets the save layer preserve almost
	// the entire file verbatim.
	Line int

	// Indent stores the whitespace indentation from the original line.  Added
	// packages default to four spaces.
	Indent string

	// Enabled is the current UI state.  Enabled packages render as:
	//   dnsx
	// Disabled packages render as:
	//   # dnsx
	Enabled bool

	// OriginalEnabled is used to decide whether the workspace is dirty and to show
	// diffs.  Added packages have OriginalEnabled == Enabled.
	OriginalEnabled bool

	// Added means TUINIX created this entry during this session.
	Added bool

	// Removed marks an entry that should be omitted on save.  The normal UI rarely
	// removes packages; moving uses TargetFile instead.
	Removed bool
}

// Changed reports whether the package differs from the disk version.
func (p *PackageEntry) Changed() bool {
	if p == nil {
		return false
	}
	if p.Added || p.Removed {
		return true
	}
	return p.Enabled != p.OriginalEnabled ||
		p.TargetFile != p.OriginalFile ||
		p.Attr != p.OriginalAttr ||
		p.Meta != p.OriginalMeta ||
		p.Section != p.OriginalSection
}

// DisplayMeta returns a compact explanation suitable for a list row.
func (p *PackageEntry) DisplayMeta() string {
	if p == nil || strings.TrimSpace(p.Meta) == "" {
		return ""
	}
	return strings.TrimSpace(p.Meta)
}

// RenderLine converts current package state back into a Nix line.
//
// The save layer calls this function, but it lives in the model because the
// rendering rule is part of the state semantics: Enabled controls whether the
// line is commented.
func (p *PackageEntry) RenderLine() string {
	indent := p.Indent
	if indent == "" {
		indent = "    "
	}

	comment := ""
	if strings.TrimSpace(p.Meta) != "" {
		comment = " # " + strings.TrimSpace(p.Meta)
	}

	if p.Enabled {
		return fmt.Sprintf("%s%s%s", indent, p.Attr, comment)
	}
	return fmt.Sprintf("%s# %s%s", indent, p.Attr, comment)
}

// NixFile represents one .nix file participating in the workspace.
type NixFile struct {
	Path string

	// Lines preserve the original file exactly enough for line-oriented saving.
	Lines []string

	// PackageBlockStart and PackageBlockEnd delimit the systemPackages list.
	// They are zero-based line indexes.  PackageBlockEnd is the closing bracket
	// line.  If the parser cannot find a block, both values are -1 and save will
	// append a simple block to the end of the file.
	PackageBlockStart int
	PackageBlockEnd   int

	Packages   []*PackageEntry
	Categories []*CategoryEntry
}

// CategoryEntry represents a package category comment inside a file.
type CategoryEntry struct {
	Name         string
	OriginalName string
	File         string
	Line         int
	Indent       string
	Added        bool
}

// BaseName is used in the file list so paths do not dominate the UI.
func (f *NixFile) BaseName() string {
	if f == nil {
		return ""
	}
	return filepath.Base(f.Path)
}

// Workspace is the complete in-memory state of all opened files.
type Workspace struct {
	Root       string
	Files      []*NixFile
	Packages   []*PackageEntry
	Categories []*CategoryEntry
}

// FileByPath returns the file object matching path, or nil.
func (w *Workspace) FileByPath(path string) *NixFile {
	for _, f := range w.Files {
		if f.Path == path {
			return f
		}
	}
	return nil
}

// FileIndexByPath returns the index of a file path, or -1 if missing.
func (w *Workspace) FileIndexByPath(path string) int {
	for i, f := range w.Files {
		if f.Path == path {
			return i
		}
	}
	return -1
}

// PackagesForFile returns all visible packages whose current target is file i.
//
// Existing packages moved away from this file disappear from this view because
// their TargetFile no longer equals f.Path.  Moved-in and newly added packages
// appear because their TargetFile points here.
func (w *Workspace) PackagesForFile(i int) []*PackageEntry {
	if w == nil || i < 0 || i >= len(w.Files) {
		return nil
	}
	path := w.Files[i].Path
	out := make([]*PackageEntry, 0)
	for _, p := range w.Packages {
		if p == nil || p.Removed {
			continue
		}
		if p.TargetFile == path {
			out = append(out, p)
		}
	}

	// Original packages keep file order.  Added/moved packages naturally sort
	// after original lines because Line == -1 gets normalized below.
	sort.SliceStable(out, func(a, b int) bool {
		pa, pb := out[a], out[b]
		la, lb := pa.Line, pb.Line
		if la < 0 {
			la = 1_000_000
		}
		if lb < 0 {
			lb = 1_000_000
		}
		if la != lb {
			return la < lb
		}
		return pa.Attr < pb.Attr
	})
	return out
}

// FilteredPackagesForFile is the same as PackagesForFile but applies a
// case-insensitive search across attr, section, and meta.
func (w *Workspace) FilteredPackagesForFile(i int, filter string) []*PackageEntry {
	pkgs := w.PackagesForFile(i)
	filter = strings.ToLower(strings.TrimSpace(filter))
	if filter == "" {
		return pkgs
	}
	out := make([]*PackageEntry, 0, len(pkgs))
	for _, p := range pkgs {
		haystack := strings.ToLower(p.Attr + " " + p.Section + " " + p.Meta)
		if strings.Contains(haystack, filter) {
			out = append(out, p)
		}
	}
	return out
}

// CategoriesForFile returns known categories for a file, preserving file order.
func (w *Workspace) CategoriesForFile(i int) []*CategoryEntry {
	if w == nil || i < 0 || i >= len(w.Files) {
		return nil
	}
	path := w.Files[i].Path
	out := make([]*CategoryEntry, 0)
	seen := map[string]bool{}
	for _, c := range w.Categories {
		if c == nil || c.File != path || strings.TrimSpace(c.Name) == "" {
			continue
		}
		key := c.Name
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, c)
	}
	sort.SliceStable(out, func(a, b int) bool {
		la, lb := out[a].Line, out[b].Line
		if la < 0 {
			la = 1_000_000
		}
		if lb < 0 {
			lb = 1_000_000
		}
		if la != lb {
			return la < lb
		}
		return out[a].Name < out[b].Name
	})
	return out
}

// FilteredPackagesAll applies a case-insensitive search across every file.
func (w *Workspace) FilteredPackagesAll(filter string) []*PackageEntry {
	if w == nil {
		return nil
	}
	filter = strings.ToLower(strings.TrimSpace(filter))
	out := make([]*PackageEntry, 0, len(w.Packages))
	for _, p := range w.Packages {
		if p == nil || p.Removed {
			continue
		}
		if filter == "" {
			out = append(out, p)
			continue
		}
		file := filepath.Base(p.TargetFile)
		haystack := strings.ToLower(p.Attr + " " + p.Section + " " + p.Meta + " " + file)
		if strings.Contains(haystack, filter) {
			out = append(out, p)
		}
	}
	sort.SliceStable(out, func(a, b int) bool {
		pa, pb := out[a], out[b]
		if pa.TargetFile != pb.TargetFile {
			return pa.TargetFile < pb.TargetFile
		}
		la, lb := pa.Line, pb.Line
		if la < 0 {
			la = 1_000_000
		}
		if lb < 0 {
			lb = 1_000_000
		}
		if la != lb {
			return la < lb
		}
		return pa.Attr < pb.Attr
	})
	return out
}

// Toggle flips the installation state of a package.
func (w *Workspace) Toggle(p *PackageEntry) {
	if p != nil {
		p.Enabled = !p.Enabled
	}
}

// AddPackage creates a new package entry in a target file.
//
// added packages are disabled by default because TUINIX often acts as a curated
// catalog.  The UI supports a small convention: if the user types "+pkg", the
// UI passes enabled=true.
func (w *Workspace) AddPackage(fileIndex int, attr, meta, section string, enabled bool) (*PackageEntry, error) {
	if w == nil || fileIndex < 0 || fileIndex >= len(w.Files) {
		return nil, fmt.Errorf("invalid file index")
	}
	attr = strings.TrimSpace(strings.TrimPrefix(attr, "+"))
	if attr == "" {
		return nil, fmt.Errorf("empty package name")
	}
	section = strings.TrimSpace(section)
	if section == "" {
		section = "TUINIX Added"
	}
	id := fmt.Sprintf("added:%s:%d", w.Files[fileIndex].Path, len(w.Packages)+1)
	p := &PackageEntry{
		ID:              id,
		Attr:            attr,
		OriginalAttr:    attr,
		Meta:            strings.TrimSpace(meta),
		OriginalMeta:    strings.TrimSpace(meta),
		Section:         section,
		OriginalSection: section,
		SectionLine:     -1,
		OriginalFile:    "",
		TargetFile:      w.Files[fileIndex].Path,
		Line:            -1,
		Indent:          "    ",
		Enabled:         enabled,
		OriginalEnabled: enabled,
		Added:           true,
	}
	w.Packages = append(w.Packages, p)
	return p, nil
}

// AddCategory creates a category comment that will be written on save.
func (w *Workspace) AddCategory(fileIndex int, name string) (*CategoryEntry, error) {
	if w == nil || fileIndex < 0 || fileIndex >= len(w.Files) {
		return nil, fmt.Errorf("invalid file index")
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, fmt.Errorf("empty category name")
	}
	path := w.Files[fileIndex].Path
	for _, c := range w.Categories {
		if c != nil && c.File == path && c.Name == name {
			return c, nil
		}
	}
	c := &CategoryEntry{
		Name:         name,
		OriginalName: name,
		File:         path,
		Line:         -1,
		Indent:       "    ",
		Added:        true,
	}
	w.Categories = append(w.Categories, c)
	return c, nil
}

// MovePackage moves a package to another file in memory.
func (w *Workspace) MovePackage(p *PackageEntry, targetFileIndex int) error {
	if p == nil {
		return fmt.Errorf("no package selected")
	}
	if targetFileIndex < 0 || targetFileIndex >= len(w.Files) {
		return fmt.Errorf("invalid target file")
	}
	p.TargetFile = w.Files[targetFileIndex].Path
	return nil
}

// EnabledCount returns active/total counts for a file.
func (w *Workspace) EnabledCount(fileIndex int) (active int, total int) {
	for _, p := range w.PackagesForFile(fileIndex) {
		total++
		if p.Enabled {
			active++
		}
	}
	return active, total
}

// Dirty reports whether any package changed.
func (w *Workspace) Dirty() bool {
	for _, p := range w.Packages {
		if p.Changed() {
			return true
		}
	}
	for _, c := range w.Categories {
		if c != nil && (c.Added || c.Name != c.OriginalName) {
			return true
		}
	}
	return false
}

// DiffLines produces a small human-readable diff summary.  It is not meant to
// be a byte-perfect unified diff; it is optimized for the right-side preview.
func (w *Workspace) DiffLines() []string {
	out := []string{"TUINIX changes", "==============", ""}
	changed := 0
	for _, p := range w.Packages {
		if !p.Changed() {
			continue
		}
		changed++
		switch {
		case p.Added:
			out = append(out, fmt.Sprintf("+ %s -> %s", p.Attr, filepath.Base(p.TargetFile)))
		case p.Removed:
			out = append(out, fmt.Sprintf("- %s from %s", p.Attr, filepath.Base(p.OriginalFile)))
		case p.TargetFile != p.OriginalFile:
			out = append(out, fmt.Sprintf("→ %s: %s -> %s", p.Attr, filepath.Base(p.OriginalFile), filepath.Base(p.TargetFile)))
		case p.Attr != p.OriginalAttr:
			out = append(out, fmt.Sprintf("~ renamed %s -> %s", p.OriginalAttr, p.Attr))
		case p.Meta != p.OriginalMeta:
			out = append(out, fmt.Sprintf("~ %s comment changed", p.Attr))
		case p.Section != p.OriginalSection:
			out = append(out, fmt.Sprintf("~ %s category: %s -> %s", p.Attr, p.OriginalSection, p.Section))
		case p.Enabled != p.OriginalEnabled:
			state := "disabled"
			if p.Enabled {
				state = "enabled"
			}
			out = append(out, fmt.Sprintf("~ %s is now %s", p.Attr, state))
		}
	}
	for _, c := range w.Categories {
		if c == nil || (!c.Added && c.Name == c.OriginalName) {
			continue
		}
		changed++
		if c.Added {
			out = append(out, fmt.Sprintf("+ category %s -> %s", c.Name, filepath.Base(c.File)))
		} else {
			out = append(out, fmt.Sprintf("~ category %s -> %s", c.OriginalName, c.Name))
		}
	}
	if changed == 0 {
		out = append(out, "No unsaved changes.")
	}
	return out
}
