// Package parser translates .nix files into the TUINIX model.
//
// This is intentionally not a complete Nix language parser.  Complete parsing
// would require a proper Nix AST and formatter.  TUINIX's job is narrower:
// find package-looking lines inside environment.systemPackages and preserve
// everything else as text.
//
// Dart analogy: this is like writing a tolerant line scanner rather than a full
// analyzer plugin.  It is optimized for user-authored package catalogs.
package parser

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"

	"tuinix/internal/model"
)

var packageAttrPattern = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_+-]*(?:\.[A-Za-z_][A-Za-z0-9_+-]*)*)(?:[[:space:]]*(?:#[[:space:]]*(.*))?)?$`)

// LoadWorkspace resolves files, parses them, and returns a model.Workspace.
func LoadWorkspace(paths []string) (*model.Workspace, error) {
	files, err := ResolveNixFiles(paths)
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("no .nix files found")
	}

	root := commonDir(files)
	w := &model.Workspace{Root: root}
	idCounter := 0
	for _, path := range files {
		nf, pkgs, err := ParseFile(path, &idCounter)
		if err != nil {
			return nil, err
		}
		w.Files = append(w.Files, nf)
		w.Packages = append(w.Packages, pkgs...)
		w.Categories = append(w.Categories, nf.Categories...)
	}
	return w, nil
}

// ResolveNixFiles accepts files or directories.  Directories are expanded to
// immediate *.nix children.  This mirrors the original Bash behavior.
func ResolveNixFiles(paths []string) ([]string, error) {
	if len(paths) == 0 {
		paths = []string{"."}
	}
	seen := map[string]bool{}
	out := []string{}
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			return nil, err
		}
		if info.IsDir() {
			matches, err := filepath.Glob(filepath.Join(p, "*.nix"))
			if err != nil {
				return nil, err
			}
			for _, m := range matches {
				abs, _ := filepath.Abs(m)
				if !seen[abs] {
					seen[abs] = true
					out = append(out, abs)
				}
			}
			continue
		}
		if strings.HasSuffix(p, ".nix") {
			abs, _ := filepath.Abs(p)
			if !seen[abs] {
				seen[abs] = true
				out = append(out, abs)
			}
		}
	}
	sort.Strings(out)
	return out, nil
}

// ParseFile reads one .nix file and extracts package entries.
func ParseFile(path string, idCounter *int) (*model.NixFile, []*model.PackageEntry, error) {
	lines, err := readLinesKeepEmpty(path)
	if err != nil {
		return nil, nil, err
	}

	nf := &model.NixFile{
		Path:              path,
		Lines:             lines,
		PackageBlockStart: -1,
		PackageBlockEnd:   -1,
	}

	inside := false
	bannerActive := false
	bannerAwaitTitle := false
	currentSection := "General"
	currentSectionLine := -1
	currentSectionIndent := ""
	pkgs := []*model.PackageEntry{}

	for i := 0; i < len(lines); i++ {
		line := lines[i]
		if !inside {
			if startsSystemPackages(line) {
				inside = true
				nf.PackageBlockStart = i
			}
			continue
		}

		if closesPackageList(line) {
			nf.PackageBlockEnd = i
			inside = false
			continue
		}

		if isBannerBorderLine(line) {
			if bannerActive {
				bannerActive = false
				bannerAwaitTitle = false
			} else {
				bannerActive = true
				bannerAwaitTitle = true
			}
			continue
		}

		if bannerActive {
			if bannerAwaitTitle {
				if section, ok := parseBannerContentLine(line); ok {
					currentSection = section
					currentSectionLine = i
					currentSectionIndent = leadingWhitespace(line)
					nf.Categories = append(nf.Categories, &model.CategoryEntry{
						Name:         section,
						OriginalName: section,
						File:         path,
						Line:         i,
						Indent:       currentSectionIndent,
					})
				}
				bannerAwaitTitle = false
			}
			continue
		}

		// Important ordering: try package parsing before section parsing.
		// Otherwise a disabled package like "# dnsx # Fast toolkit" would be
		// mistaken for a comment header.  This was the real bug in early versions.
		if pkg, ok := parsePackageLine(line, path, i, currentSection, currentSectionLine, currentSectionIndent, idCounter); ok {
			if doc, endLine, ok := parseMarkdownBlockAfterPackage(lines, i+1); ok {
				pkg.DocMarkdown = doc
				i = endLine
			}
			pkgs = append(pkgs, pkg)
			nf.Packages = append(nf.Packages, pkg)
			continue
		}

		if section, ok := parseSectionLine(line); ok {
			currentSection = section
			currentSectionLine = i
			currentSectionIndent = leadingWhitespace(line)
			nf.Categories = append(nf.Categories, &model.CategoryEntry{
				Name:         section,
				OriginalName: section,
				File:         path,
				Line:         i,
				Indent:       currentSectionIndent,
			})
		}
	}

	return nf, pkgs, nil
}

// readLinesKeepEmpty preserves empty lines and gives stable line numbers.
func readLinesKeepEmpty(path string) ([]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	s := strings.ReplaceAll(string(b), "\r\n", "\n")
	// strings.Split keeps empty elements, including a final empty element when the
	// file ends with a newline.  That is acceptable for line-oriented rewriting.
	return strings.Split(s, "\n"), nil
}

func startsSystemPackages(line string) bool {
	code := strings.TrimSpace(beforeInlineComment(line))
	return strings.Contains(code, "environment.systemPackages") && strings.Contains(code, "[")
}

func closesPackageList(line string) bool {
	code := strings.TrimSpace(beforeInlineComment(line))
	return strings.HasPrefix(code, "]") || strings.HasPrefix(code, "];")
}

func beforeInlineComment(line string) string {
	// This intentionally ignores # inside strings.  TUINIX package-list files do
	// not normally use strings in systemPackages.  The trade-off keeps the parser
	// easy to audit and robust for comments that include brackets.
	if idx := strings.Index(line, "#"); idx >= 0 {
		return line[:idx]
	}
	return line
}

func parsePackageLine(line, file string, lineNo int, section string, sectionLine int, sectionIndent string, idCounter *int) (*model.PackageEntry, bool) {
	indent := leadingWhitespace(line)
	s := strings.TrimSpace(line)
	if s == "" {
		return nil, false
	}

	enabled := true
	if strings.HasPrefix(s, "#") {
		enabled = false
		s = strings.TrimSpace(strings.TrimPrefix(s, "#"))
	}

	if s == "" || strings.HasPrefix(s, "#") {
		return nil, false
	}
	if looksLikeNonPackage(s) {
		return nil, false
	}

	m := packageAttrPattern.FindStringSubmatch(s)
	if m == nil {
		return nil, false
	}
	attr := strings.TrimSpace(m[1])
	meta := ""
	if len(m) > 2 {
		meta = strings.TrimSpace(m[2])
	}
	if isReservedWord(attr) {
		return nil, false
	}

	*idCounter = *idCounter + 1
	id := fmt.Sprintf("pkg:%d", *idCounter)
	return &model.PackageEntry{
		ID:              id,
		Attr:            attr,
		OriginalAttr:    attr,
		Meta:            meta,
		OriginalMeta:    meta,
		Section:         section,
		OriginalSection: section,
		SectionLine:     sectionLine,
		SectionIndent:   sectionIndent,
		OriginalFile:    file,
		TargetFile:      file,
		Line:            lineNo,
		Indent:          indent,
		Enabled:         enabled,
		OriginalEnabled: enabled,
	}, true
}

func parseMarkdownBlockAfterPackage(lines []string, start int) (string, int, bool) {
	if start >= len(lines) {
		return "", start, false
	}
	line := strings.TrimSpace(lines[start])
	if !strings.HasPrefix(line, "/*") {
		return "", start, false
	}

	content := []string{}
	rest := strings.TrimSpace(strings.TrimPrefix(line, "/*"))
	if idx := strings.Index(rest, "*/"); idx >= 0 {
		before := strings.TrimSpace(rest[:idx])
		if before != "" {
			content = append(content, before)
		}
		return strings.TrimSpace(strings.Join(content, "\n")), start, true
	}
	if rest != "" {
		content = append(content, rest)
	}

	for i := start + 1; i < len(lines); i++ {
		s := lines[i]
		if idx := strings.Index(s, "*/"); idx >= 0 {
			before := strings.TrimSpace(s[:idx])
			if before != "" {
				content = append(content, before)
			}
			return strings.TrimSpace(strings.Join(content, "\n")), i, true
		}
		content = append(content, strings.TrimRight(s, " \t"))
	}
	return strings.TrimSpace(strings.Join(content, "\n")), len(lines) - 1, true
}

func leadingWhitespace(s string) string {
	idx := 0
	for idx < len(s) {
		r := rune(s[idx])
		if r != ' ' && r != '\t' {
			break
		}
		idx++
	}
	return s[:idx]
}

func looksLikeNonPackage(s string) bool {
	if strings.Contains(s, "=") || strings.Contains(s, "{") || strings.Contains(s, "}") {
		return true
	}
	if strings.HasPrefix(s, "[") || strings.HasPrefix(s, "]") || strings.HasPrefix(s, ";") {
		return true
	}
	if strings.Contains(s, "://") && !strings.Contains(s, "#") {
		return true
	}
	return false
}

func isReservedWord(s string) bool {
	switch s {
	case "let", "in", "with", "if", "then", "else", "rec", "true", "false", "null", "pkgs", "lib":
		return true
	default:
		return false
	}
}

func parseSectionLine(line string) (string, bool) {
	s := strings.TrimSpace(line)
	if !strings.HasPrefix(s, "#") {
		return "", false
	}
	s = strings.TrimSpace(strings.TrimPrefix(s, "#"))
	return normalizeSectionText(s)
}

func isBannerBorderLine(line string) bool {
	s := strings.TrimSpace(line)
	if !strings.HasPrefix(s, "#") {
		return false
	}
	s = strings.TrimSpace(strings.TrimPrefix(s, "#"))
	if s == "" {
		return false
	}
	hasBorder := strings.ContainsAny(s, "▐▌┌┐└┘")
	if !hasBorder {
		return false
	}
	withoutBorders := stripSectionDecorators(s)
	return strings.TrimSpace(withoutBorders) == "" || onlyPunctuation(withoutBorders)
}

func parseBannerContentLine(line string) (string, bool) {
	s := strings.TrimSpace(line)
	if !strings.HasPrefix(s, "#") {
		return "", false
	}
	s = strings.TrimSpace(strings.TrimPrefix(s, "#"))
	if !strings.ContainsAny(s, "▐▌┃│") {
		return "", false
	}
	return normalizeSectionText(s)
}

func normalizeSectionText(s string) (string, bool) {
	if s == "" {
		return "", false
	}
	// Remove common box-drawing characters used in Leonardo's package catalogs.
	s = stripSectionDecorators(s)
	s = strings.TrimSpace(s)
	if s == "" || onlyPunctuation(s) {
		return "", false
	}
	if len([]rune(s)) > 80 {
		return "", false
	}
	return s, true
}

func stripSectionDecorators(s string) string {
	return strings.Map(func(r rune) rune {
		switch r {
		case '▐', '▌', '▀', '▄', '═', '─', '━', '┃', '│', '┌', '┐', '└', '┘':
			return -1
		default:
			return r
		}
	}, s)
}

func onlyPunctuation(s string) bool {
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return false
		}
	}
	return true
}

func commonDir(files []string) string {
	if len(files) == 0 {
		cwd, _ := os.Getwd()
		return cwd
	}
	return filepath.Dir(files[0])
}
