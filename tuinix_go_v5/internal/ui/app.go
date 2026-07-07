// Package ui contains the Bubble Tea state machine.
//
// Bubble Tea uses an architecture very close to Flutter/Dart ideas, but with a
// terminal flavor:
//   - Model: immutable-ish application state.  In Go this is usually a struct.
//   - Update: receives events and returns the next state plus optional command.
//   - View: renders state to a string.
//
// Flutter analogy:
//   - tea.Model.Update is similar to reacting to events in setState / Bloc.
//   - tea.Model.View is similar to build(), except it returns terminal text.
//   - tea.Cmd is similar to scheduling an async side effect that later emits an
//     event.  TUINIX keeps commands minimal and performs small file operations
//     synchronously because package catalogs are small.
package ui

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"tuinix/internal/defaultnix"
	"tuinix/internal/gitctl"
	"tuinix/internal/model"
	"tuinix/internal/nixos"
	"tuinix/internal/parser"
	"tuinix/internal/save"
)

const version = "α"

type mode int

const (
	modeNormal mode = iota
	modeSearch
	modeGlobalSearch
	modeNixSearch
	modeNixFlakeSearch
	modeAdd
	modeAddCategory
	modeAddFile
	modeMove
	modeRename
	modeComment
	modeSwitchConfirm
)

type rightView int

const (
	rightDetail rightView = iota
	rightDiff
	rightGit
)

const (
	focusFiles = iota
	focusPackages
	focusScripts
)

type contextAction int

const (
	contextToggle contextAction = iota
	contextRename
	contextMove
	contextComment
	contextRun
)

type contextKind int

const (
	contextKindPackage contextKind = iota
	contextKindFile
)

type contextMenu struct {
	Open         bool
	Kind         contextKind
	PackageIndex int
	FileIndex    int
	Row          int
	Col          int
	Cursor       int
}

type commandFinishedMsg struct {
	Attr string
	Err  error
}

type switchStreamMsg struct {
	Text string
	Err  error
	Done bool
}

type packageRow struct {
	Header       bool
	Section      string
	Package      *model.PackageEntry
	PackageIndex int
}

// App is the root Bubble Tea model.
//
// Go note for Dart developers: fields are mutable here.  Bubble Tea examples
// often return a copied value, but mutation inside Update is idiomatic for small
// terminal applications and avoids deep copies of the workspace.
type App struct {
	Workspace  *model.Workspace
	InputPaths []string

	FileCursor   int
	PkgCursor    int
	ScriptCursor int
	FileOffset   int
	PkgOffset    int
	ScriptOffset int
	Focus        int
	Scripts      []string

	Mode           mode
	Right          rightView
	Input          []rune
	Filter         string
	Message        string
	MoveCursor     int
	Context        contextMenu
	SearchAll      bool
	SwitchOutput   string
	SwitchRunning  bool
	SwitchStream   <-chan switchStreamMsg
	SwitchTitle    string
	SwitchRunAfter bool
	SwitchRunAttrs []string

	LastClickPackage int
	LastClickTime    time.Time

	ShowHelp      bool
	HeaderVisible bool
	FooterVisible bool

	DefaultNixState *defaultnix.State

	Width  int
	Height int
}

// New creates the initial app model.
func New(w *model.Workspace, inputPaths []string) App {
	app := App{
		Workspace:     w,
		InputPaths:    inputPaths,
		Scripts:       loadScripts(w),
		Focus:         focusPackages,
		Right:         rightDetail,
		Message:       "ready",
		HeaderVisible: true,
		FooterVisible: true,
	}
	if p := defaultnix.Find(inputPaths); p != "" {
		if s, err := defaultnix.Parse(p); err == nil {
			app.DefaultNixState = s
		}
	}
	return app
}

// Init is part of tea.Model.  Returning nil means no startup command.
func (a App) Init() tea.Cmd { return nil }

// Update is the event reducer.  Every keypress, mouse click, or terminal resize
// reaches this method.
func (a App) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		a.Width, a.Height = msg.Width, msg.Height
		a.ensureVisible()
		return a, nil
	case tea.MouseMsg:
		return a.handleMouse(msg)
	case commandFinishedMsg:
		if msg.Err != nil {
			a.Message = "command failed: " + msg.Err.Error()
		} else {
			a.Message = "command finished: " + msg.Attr
		}
		return a, nil
	case switchStreamMsg:
		if msg.Text != "" {
			a.SwitchOutput += msg.Text
		}
		if msg.Done {
			a.SwitchRunning = false
			a.SwitchStream = nil
			if strings.TrimSpace(a.SwitchOutput) == "" {
				a.SwitchOutput = "(sem output)"
			}
			if msg.Err != nil {
				a.Message = "command failed: " + a.SwitchTitle
				a.SwitchOutput += "\nERROR: " + msg.Err.Error()
			} else {
				a.Message = "command finished: " + a.SwitchTitle
			}
			return a, nil
		}
		return a, waitSwitchStream(a.SwitchStream)
	case tea.KeyMsg:
		return a.handleKey(msg)
	default:
		return a, nil
	}
}

func (a App) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if a.ShowHelp {
		switch msg.String() {
		case "esc", "enter", "f1", "q", "?":
			a.ShowHelp = false
		case "f12":
			a.FooterVisible = !a.FooterVisible
			a.ensureVisible()
		}
		return a, nil
	}
	if a.SwitchOutput != "" && !a.SwitchRunning {
		switch msg.String() {
		case "esc", "enter", "q":
			a.SwitchOutput = ""
		}
		return a, nil
	}
	if a.SwitchRunning {
		return a, nil
	}
	// Modal input states get first chance to consume keys.
	switch a.Mode {
	case modeSearch:
		return a.updateTextInput(msg, func(text string) {
			a.Filter = text
			a.SearchAll = false
			a.PkgCursor = 0
			a.PkgOffset = 0
			a.Message = "filter applied"
		})
	case modeGlobalSearch:
		model, cmd := a.updateTextInput(msg, func(text string) {
			a.Filter = text
			a.SearchAll = true
			a.PkgCursor = 0
			a.PkgOffset = 0
			a.Focus = focusPackages
			a.Message = "global search applied"
		})
		// Apply filter live while typing so results are visible immediately.
		app := model.(App)
		app.Filter = strings.TrimSpace(string(app.Input))
		app.SearchAll = true
		return app, cmd
	case modeNixSearch:
		return a.updateTextInput(msg, func(text string) {
			a.runNixSearch(text)
		})
	case modeNixFlakeSearch:
		return a.updateTextInput(msg, func(text string) {
			a.runNixFlakeSearch(text)
		})
	case modeAdd:
		return a.updateTextInput(msg, func(text string) {
			enabled := strings.HasPrefix(strings.TrimSpace(text), "+")
			if _, err := a.Workspace.AddPackage(a.targetFileIndex(), text, "added by TUINIX", a.selectedSection(), enabled); err != nil {
				a.Message = err.Error()
			} else {
				a.Message = "package added"
				a.Right = rightDetail
			}
		})
	case modeAddCategory:
		return a.updateTextInput(msg, func(text string) {
			if _, err := a.Workspace.AddCategory(a.targetFileIndex(), text); err != nil {
				a.Message = err.Error()
			} else {
				a.SearchAll = false
				a.Message = "category added in memory; press s to save"
			}
		})
	case modeAddFile:
		return a.updateTextInput(msg, func(text string) {
			a.addFile(text)
		})
	case modeMove:
		return a.updateMoveMode(msg), nil
	case modeRename:
		return a.updateTextInput(msg, func(text string) {
			a.renameSelected(text)
		})
	case modeComment:
		return a.updateTextInput(msg, func(text string) {
			a.updateSelectedComment(text)
		})
	case modeSwitchConfirm:
		return a.updateSwitchConfirm(msg)
	}

	if a.Context.Open {
		return a.handleContextKey(msg)
	}

	switch msg.String() {
	case "ctrl+c", "q":
		return a, tea.Quit
	case "f1", "?":
		a.ShowHelp = true
	case "f12":
		a.FooterVisible = !a.FooterVisible
		a.ensureVisible()
	case "tab":
		switch a.Focus {
		case focusFiles:
			a.Focus = focusPackages
		case focusPackages:
			a.Focus = focusScripts
		default:
			a.Focus = focusFiles
		}
	case "esc":
		if a.Filter != "" {
			a.Filter = ""
			a.SearchAll = false
			a.PkgCursor = 0
			a.PkgOffset = 0
			a.Message = "filter cleared"
		}
	case "up", "k":
		a.moveCursor(-1)
	case "down", "j":
		a.moveCursor(1)
	case "left", "h":
		a.moveFile(-1)
	case "right", "l":
		a.moveFile(1)
	case " ", "enter":
		if a.Focus == focusScripts {
			return a.runSelectedScript()
		}
		a.toggleSelected()
	case "/":
		a.Mode = modeSearch
		a.Input = []rune(a.Filter)
		a.Message = "type filter and press Enter"
	case "f3", "f":
		a.Mode = modeGlobalSearch
		a.Input = []rune(a.Filter)
		a.SearchAll = true
		a.PkgCursor = 0
		a.PkgOffset = 0
		a.Message = "global search across all files"
	case "p":
		a.Mode = modeNixSearch
		a.Input = nil
		a.Message = "type nixpkgs search keyword"
	case "ctrl+f3", "F":
		a.Mode = modeNixFlakeSearch
		a.Input = nil
		a.Message = "type nix search flake keyword"
	case "n":
		a.Mode = modeAdd
		a.Input = nil
		a.Message = "type package attr; prefix with + to add enabled"
	case "N":
		a.Mode = modeAddCategory
		a.Input = nil
		a.Message = "type category name"
	case "f2", "r":
		if p := a.selectedPackage(); p != nil {
			a.Mode = modeRename
			a.Input = []rune(p.Attr)
			a.Message = "rename package; prefix cat: to rename category"
		}
	case "m":
		a.startMoveSelected()
	case "f4", "c":
		if p := a.selectedPackage(); p != nil {
			a.Mode = modeComment
			a.Input = []rune(p.DisplayMeta())
			a.Message = "edit comment and press Enter"
		}
	case "f5", "R":
		a.reloadWorkspace()
	case "s":
		a.saveWorkspace()
	case "S":
		return a.startNixosSwitch(false)
	case "d":
		a.Right = rightDiff
	case "g":
		a.Right = rightGit
	case "e":
		a.toggleFileImport()
	case "G":
		a.jumpToPackageFile()
	case "o":
		a.openSelectedPackage()
	case "i":
		a.initGit()
	case "C":
		a.commitGit()
	}
	return a, nil
}

func (a App) handleContextKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		a.Context.Open = false
		a.Message = "context menu closed"
	case "up", "k":
		if a.Context.Cursor > 0 {
			a.Context.Cursor--
		}
	case "down", "j":
		if a.Context.Cursor < len(a.contextMenuLabels())-1 {
			a.Context.Cursor++
		}
	case "enter":
		return a.runContextAction(contextAction(a.Context.Cursor))
	default:
		a.Context.Open = false
		return a.handleKey(msg)
	}
	return a, nil
}

// updateTextInput is a small reusable text-field implementation.  Bubble Tea has
// a separate bubbles/textinput component, but avoiding it keeps the tutorial
// code compact and dependency-light.
func (a App) updateTextInput(msg tea.KeyMsg, onSubmit func(string)) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		oldMode := a.Mode
		a.Mode = modeNormal
		a.Input = nil
		if oldMode == modeGlobalSearch {
			a.SearchAll = false
		}
		a.Message = "cancelled"
	case "enter":
		text := strings.TrimSpace(string(a.Input))
		oldMode := a.Mode
		a.Mode = modeNormal
		a.Input = nil
		if text != "" || oldMode == modeComment || oldMode == modeGlobalSearch {
			onSubmit(text)
		}
	case "backspace", "ctrl+h":
		if len(a.Input) > 0 {
			a.Input = a.Input[:len(a.Input)-1]
		}
	default:
		// Bubble Tea keeps printable text in KeyMsg.Runes.  Using Runes is
		// safer than msg.String(): the space key should append ' ', not the
		// literal word "space".
		if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
			if msg.Type == tea.KeySpace && len(msg.Runes) == 0 {
				a.Input = append(a.Input, ' ')
			} else {
				a.Input = append(a.Input, msg.Runes...)
			}
		}
	}
	return a, nil
}

func (a App) updateMoveMode(msg tea.KeyMsg) App {
	switch msg.String() {
	case "esc":
		a.Mode = modeNormal
		a.Message = "move cancelled"
	case "up", "k":
		if a.MoveCursor > 0 {
			a.MoveCursor--
		}
	case "down", "j":
		if a.MoveCursor < len(a.Workspace.Files)-1 {
			a.MoveCursor++
		}
	case "enter":
		p := a.selectedPackage()
		if p == nil {
			a.Message = "no package selected"
		} else if err := a.Workspace.MovePackage(p, a.MoveCursor); err != nil {
			a.Message = err.Error()
		} else {
			a.FileCursor = a.MoveCursor
			a.PkgCursor = 0
			a.FileOffset = 0
			a.PkgOffset = 0
			a.Mode = modeNormal
			a.Message = "package moved in memory; press s to save"
		}
	}
	a.ensureVisible()
	return a
}

func (a App) updateSwitchConfirm(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		a.Mode = modeNormal
		a.Message = "nixos-rebuild switch cancelled"
	case "s", "S", "y", "Y":
		if err := a.saveWorkspaceWithReload(); err != nil {
			a.Mode = modeNormal
			a.Message = "save failed: " + err.Error()
			return a, nil
		}
		a.Mode = modeNormal
		return a.runNixosSwitch()
	case "n", "N":
		a.Mode = modeNormal
		return a.runNixosSwitch()
	}
	return a, nil
}

func (a App) handleMouse(msg tea.MouseMsg) (App, tea.Cmd) {
	if msg.Action == tea.MouseActionRelease {
		return a, nil
	}
	if msg.Type == tea.MouseLeft && msg.Y == a.topRows()+a.bodyHeight() {
		switch a.headerButtonAt(msg.X) {
		case "help":
			a.ShowHelp = true
			return a, nil
		case "header":
			a.HeaderVisible = !a.HeaderVisible
			a.ensureVisible()
			return a, nil
		}
	}
	if msg.Type == tea.MouseLeft && a.FooterVisible {
		if action := a.footerButtonAt(msg.X, msg.Y); action == "footer" {
			a.FooterVisible = !a.FooterVisible
			a.ensureVisible()
			return a, nil
		}
	}
	if a.Context.Open && msg.Type == tea.MouseLeft {
		if action, ok := a.contextActionAt(msg); ok {
			return a.runContextAction(action)
		}
		a.Context.Open = false
	}
	leftW, midW := a.panelWidths()
	top := a.topRows()
	row := msg.Y - top
	if row < 0 {
		return a, nil
	}
	filesH, scriptsH := a.leftPanelHeights(a.bodyHeight())
	if msg.Type == tea.MouseWheelUp || msg.Type == tea.MouseWheelDown {
		delta := 3
		if msg.Type == tea.MouseWheelUp {
			delta = -3
		}
		if msg.X < leftW {
			if row > filesH {
				a.scrollScripts(delta, scriptsH)
			} else {
				a.scrollFiles(delta)
			}
		} else if msg.X < leftW+midW {
			a.scrollPackages(delta)
		}
		return a, nil
	}
	if msg.Type == tea.MouseRight {
		if row >= 0 && msg.X < leftW && row < filesH {
			fileIndex := a.fileViewportOffset(filesH) + row
			if fileIndex >= 0 && fileIndex < len(a.Workspace.Files) {
				menuRow := a.clampedMenuRow(row, len(fileContextMenuLabels()), filesH)
				a.FileCursor = fileIndex
				a.Focus = focusFiles
				a.Context = contextMenu{
					Open:      true,
					Kind:      contextKindFile,
					FileIndex: fileIndex,
					Row:       menuRow,
					Col:       contextMenuColumn(msg.X, 0, leftW, maxLabelWidth(fileContextMenuLabels())),
				}
				a.Message = "file menu: choose action"
			}
		} else if row >= 0 && msg.X >= leftW && msg.X < leftW+midW {
			rows := a.packageRows()
			rowIndex := a.packageViewportOffset(a.bodyHeight()) + row
			if rowIndex >= 0 && rowIndex < len(rows) && !rows[rowIndex].Header {
				menuRow := a.clampedMenuRow(row, len(packageContextMenuLabels()), a.bodyHeight())
				a.PkgCursor = rows[rowIndex].PackageIndex
				a.Focus = focusPackages
				a.Context = contextMenu{
					Open:         true,
					Kind:         contextKindPackage,
					PackageIndex: rows[rowIndex].PackageIndex,
					Row:          menuRow,
					Col:          contextMenuColumn(msg.X, leftW, midW, maxLabelWidth(packageContextMenuLabels())),
				}
				a.Message = "context menu: choose action"
			}
		}
		return a, nil
	}
	if msg.Type != tea.MouseLeft {
		return a, nil
	}
	if msg.X < leftW {
		if row < filesH {
			fileIndex := a.fileViewportOffset(filesH) + row
			if fileIndex >= 0 && fileIndex < len(a.Workspace.Files) {
				a.FileCursor = fileIndex
				a.PkgCursor = 0
				a.PkgOffset = 0
				a.Focus = focusFiles
				a.Right = rightDetail
				a.ensureFileVisible()
			}
			return a, nil
		}
		if row > filesH {
			scriptRow := row - filesH - 1
			offset := a.scriptViewportOffset(scriptsH)
			if scriptRow == scriptsH-3 && len(a.Scripts) > 0 {
				a.Focus = focusScripts
				return a.runSelectedScript()
			}
			if scriptRow == scriptsH-2 {
				a.Focus = focusScripts
				return a.startNixosSwitch(false)
			}
			if scriptRow == scriptsH-1 {
				a.Focus = focusScripts
				return a.startNixosSwitch(true)
			}
			scriptIndex := offset + scriptRow
			if scriptIndex >= 0 && scriptIndex < len(a.Scripts) {
				a.ScriptCursor = scriptIndex
				a.Focus = focusScripts
				a.ensureScriptVisible()
				a.Message = "script selected"
			}
		}
		return a, nil
	}
	if msg.X < leftW+midW {
		rows := a.packageRows()
		rowIndex := a.packageViewportOffset(a.bodyHeight()) + row
		if rowIndex >= 0 && rowIndex < len(rows) && !rows[rowIndex].Header {
			a.PkgCursor = rows[rowIndex].PackageIndex
			a.Focus = focusPackages
			now := time.Now()
			if a.LastClickPackage == rows[rowIndex].PackageIndex && now.Sub(a.LastClickTime) <= 500*time.Millisecond {
				a.Workspace.Toggle(rows[rowIndex].Package)
				a.Message = "package toggled"
			} else {
				a.Message = "package selected"
			}
			a.LastClickPackage = rows[rowIndex].PackageIndex
			a.LastClickTime = now
		}
		return a, nil
	}
	return a, nil
}

func (a App) headerButtonAt(x int) string {
	helpStart, helpEnd, footerStart, footerEnd := a.headerButtonColumns()
	switch {
	case x >= helpStart && x < helpEnd:
		return "help"
	case x >= footerStart && x < footerEnd:
		return "header"
	default:
		return ""
	}
}

func (a App) footerButtonAt(x, y int) string {
	if !a.FooterVisible {
		return ""
	}
	if y != a.footerButtonRow() {
		return ""
	}
	start, end := a.footerButtonColumns()
	if x >= start && x < end {
		return "footer"
	}
	return ""
}

func (a App) footerButtonRow() int {
	return 1
}

func (a App) footerButtonColumns() (start, end int) {
	label := "[F12 Rodape]"
	if !a.FooterVisible {
		label = "[F12 Rodape off]"
	}
	width := utf8.RuneCountInString(label)
	end = a.Width
	start = end - width
	if start < 0 {
		start = 0
	}
	return start, end
}

func (a App) clampedMenuRow(row, labels, height int) int {
	menuRow := row
	if maxRow := height - labels; menuRow > maxRow {
		menuRow = maxRow
	}
	if menuRow < 0 {
		menuRow = 0
	}
	return menuRow
}

func (a *App) moveCursor(delta int) {
	if a.Focus == focusFiles {
		a.moveFile(delta)
		return
	}
	if a.Focus == focusScripts {
		a.moveScript(delta)
		return
	}
	pkgs := a.visiblePackages()
	if len(pkgs) == 0 {
		a.PkgCursor = 0
		return
	}
	a.PkgCursor += delta
	if a.PkgCursor < 0 {
		a.PkgCursor = 0
	}
	if a.PkgCursor >= len(pkgs) {
		a.PkgCursor = len(pkgs) - 1
	}
	a.ensurePackageVisible()
}

func (a *App) moveFile(delta int) {
	if len(a.Workspace.Files) == 0 {
		return
	}
	a.FileCursor += delta
	if a.FileCursor < 0 {
		a.FileCursor = 0
	}
	if a.FileCursor >= len(a.Workspace.Files) {
		a.FileCursor = len(a.Workspace.Files) - 1
	}
	a.PkgCursor = 0
	a.PkgOffset = 0
	a.ensureFileVisible()
}

func (a *App) moveScript(delta int) {
	if len(a.Scripts) == 0 {
		a.ScriptCursor = 0
		return
	}
	a.ScriptCursor += delta
	if a.ScriptCursor < 0 {
		a.ScriptCursor = 0
	}
	if a.ScriptCursor >= len(a.Scripts) {
		a.ScriptCursor = len(a.Scripts) - 1
	}
	a.ensureScriptVisible()
}

func (a *App) toggleSelected() {
	if p := a.selectedPackage(); p != nil {
		a.Workspace.Toggle(p)
		a.Message = "package toggled"
	}
}

func (a App) visiblePackages() []*model.PackageEntry {
	if a.SearchAll {
		return a.Workspace.FilteredPackagesAll(a.Filter)
	}
	return a.Workspace.FilteredPackagesForFile(a.FileCursor, a.Filter)
}

func (a App) selectedPackage() *model.PackageEntry {
	pkgs := a.visiblePackages()
	if a.PkgCursor < 0 || a.PkgCursor >= len(pkgs) {
		return nil
	}
	return pkgs[a.PkgCursor]
}

func (a App) packageRows() []packageRow {
	pkgs := a.visiblePackages()
	rows := make([]packageRow, 0, len(pkgs)*2)
	lastSection := ""
	seenSections := map[string]bool{}
	for i, p := range pkgs {
		section := strings.TrimSpace(p.Section)
		if section == "" {
			section = "General"
		}
		seenSections[section] = true
		if a.SearchAll {
			section = filepath.Base(p.TargetFile) + " / " + section
		}
		if section != lastSection {
			rows = append(rows, packageRow{Header: true, Section: section, PackageIndex: -1})
			lastSection = section
		}
		rows = append(rows, packageRow{Package: p, PackageIndex: i, Section: section})
	}
	if !a.SearchAll && strings.TrimSpace(a.Filter) == "" {
		for _, c := range a.Workspace.CategoriesForFile(a.FileCursor) {
			if c == nil || seenSections[c.Name] {
				continue
			}
			rows = append(rows, packageRow{Header: true, Section: c.Name, PackageIndex: -1})
		}
	}
	return rows
}

func (a App) packageCursorRow() int {
	for i, row := range a.packageRows() {
		if !row.Header && row.PackageIndex == a.PkgCursor {
			return i
		}
	}
	return 0
}

func (a App) packageViewportOffset(height int) int {
	rows := a.packageRows()
	return clampOffset(a.PkgOffset, len(rows), height)
}

func (a App) fileViewportOffset(height int) int {
	return clampOffset(a.FileOffset, len(a.Workspace.Files), height)
}

func (a App) scriptViewportOffset(height int) int {
	return clampOffset(a.ScriptOffset, len(a.Scripts), scriptListHeight(height))
}

func clampOffset(offset, total, height int) int {
	if height < 1 || total <= height {
		return 0
	}
	maxOffset := total - height
	if offset < 0 {
		return 0
	}
	if offset > maxOffset {
		return maxOffset
	}
	return offset
}

func (a *App) ensureVisible() {
	a.ensureFileVisible()
	a.ensurePackageVisible()
	a.ensureScriptVisible()
}

func (a *App) ensureFileVisible() {
	filesH, _ := a.leftPanelHeights(a.bodyHeight())
	height := filesH
	if a.FileCursor < a.FileOffset {
		a.FileOffset = a.FileCursor
	}
	if a.FileCursor >= a.FileOffset+height {
		a.FileOffset = a.FileCursor - height + 1
	}
	a.FileOffset = clampOffset(a.FileOffset, len(a.Workspace.Files), height)
}

func (a *App) ensureScriptVisible() {
	_, scriptsH := a.leftPanelHeights(a.bodyHeight())
	height := scriptListHeight(scriptsH)
	if a.ScriptCursor < a.ScriptOffset {
		a.ScriptOffset = a.ScriptCursor
	}
	if a.ScriptCursor >= a.ScriptOffset+height {
		a.ScriptOffset = a.ScriptCursor - height + 1
	}
	a.ScriptOffset = clampOffset(a.ScriptOffset, len(a.Scripts), height)
}

func (a *App) ensurePackageVisible() {
	height := a.bodyHeight()
	cursorRow := a.packageCursorRow()
	if cursorRow < a.PkgOffset {
		a.PkgOffset = cursorRow
	}
	if cursorRow >= a.PkgOffset+height {
		a.PkgOffset = cursorRow - height + 1
	}
	a.PkgOffset = clampOffset(a.PkgOffset, len(a.packageRows()), height)
}

func (a *App) scrollFiles(delta int) {
	filesH, _ := a.leftPanelHeights(a.bodyHeight())
	a.FileOffset = clampOffset(a.FileOffset+delta, len(a.Workspace.Files), filesH)
	if a.FileCursor < a.FileOffset {
		a.FileCursor = a.FileOffset
	}
	lastVisible := a.FileOffset + filesH - 1
	if a.FileCursor > lastVisible {
		a.FileCursor = lastVisible
	}
	if a.FileCursor >= len(a.Workspace.Files) {
		a.FileCursor = len(a.Workspace.Files) - 1
	}
	if a.FileCursor < 0 {
		a.FileCursor = 0
	}
}

func (a *App) scrollScripts(delta, height int) {
	listH := scriptListHeight(height)
	a.ScriptOffset = clampOffset(a.ScriptOffset+delta, len(a.Scripts), listH)
	if a.ScriptCursor < a.ScriptOffset {
		a.ScriptCursor = a.ScriptOffset
	}
	lastVisible := a.ScriptOffset + listH - 1
	if a.ScriptCursor > lastVisible {
		a.ScriptCursor = lastVisible
	}
	if a.ScriptCursor >= len(a.Scripts) {
		a.ScriptCursor = len(a.Scripts) - 1
	}
	if a.ScriptCursor < 0 {
		a.ScriptCursor = 0
	}
}

func (a *App) scrollPackages(delta int) {
	rows := a.packageRows()
	a.PkgOffset = clampOffset(a.PkgOffset+delta, len(rows), a.bodyHeight())
	for i := a.PkgOffset; i < len(rows) && i < a.PkgOffset+a.bodyHeight(); i++ {
		if !rows[i].Header {
			a.PkgCursor = rows[i].PackageIndex
			return
		}
	}
}

func (a *App) openSelectedPackage() {
	p := a.selectedPackage()
	if p == nil {
		a.Message = "no package selected"
		return
	}
	if err := nixos.OpenSearch(p.Attr); err != nil {
		a.Message = "open failed: " + err.Error()
		return
	}
	a.Message = "opened NixOS Search for " + p.Attr
}

func (a App) runContextAction(action contextAction) (App, tea.Cmd) {
	if a.Context.Kind == contextKindFile {
		a.FileCursor = a.Context.FileIndex
		a.Context.Open = false
		switch action {
		case 0:
			a.Mode = modeAddFile
			a.Input = nil
			a.Message = "type new .nix file name"
		case 1:
			a.Mode = modeAddCategory
			a.Input = nil
			a.Message = "type category name"
		}
		return a, nil
	}
	if a.Context.PackageIndex >= 0 {
		a.PkgCursor = a.Context.PackageIndex
	}
	a.Context.Open = false
	switch action {
	case contextToggle:
		a.toggleSelected()
	case contextRename:
		if p := a.selectedPackage(); p != nil {
			a.Mode = modeRename
			a.Input = []rune(p.Attr)
			a.Message = "rename package; prefix cat: to rename category"
		}
	case contextMove:
		a.startMoveSelected()
	case contextComment:
		if p := a.selectedPackage(); p != nil {
			a.Mode = modeComment
			a.Input = []rune(p.DisplayMeta())
			a.Message = "edit comment and press Enter"
		}
	case contextRun:
		return a.runSelectedPackageCommand()
	}
	return a, nil
}

func (a App) targetFileIndex() int {
	if p := a.selectedPackage(); p != nil {
		if idx := a.Workspace.FileIndexByPath(p.TargetFile); idx >= 0 {
			return idx
		}
	}
	return a.FileCursor
}

func (a App) selectedSection() string {
	if p := a.selectedPackage(); p != nil && strings.TrimSpace(p.Section) != "" {
		return p.Section
	}
	return "TUINIX Added"
}

func (a *App) startMoveSelected() {
	p := a.selectedPackage()
	if p == nil {
		return
	}
	if idx := a.Workspace.FileIndexByPath(p.TargetFile); idx >= 0 {
		a.MoveCursor = idx
	} else {
		a.MoveCursor = a.FileCursor
	}
	a.Mode = modeMove
	a.Message = "choose target file and press Enter"
}

func (a *App) renameSelected(text string) {
	p := a.selectedPackage()
	if p == nil {
		a.Message = "no package selected"
		return
	}
	text = strings.TrimSpace(text)
	if text == "" {
		a.Message = "empty name ignored"
		return
	}
	if category, ok := strings.CutPrefix(text, "cat:"); ok {
		a.renameCategory(strings.TrimSpace(category), p)
		return
	}
	p.Attr = text
	a.Message = "package renamed in memory; press s to save"
}

func (a *App) renameCategory(name string, selected *model.PackageEntry) {
	if name == "" {
		a.Message = "empty category ignored"
		return
	}
	oldSection := selected.Section
	file := selected.TargetFile
	changed := 0
	for _, p := range a.Workspace.Packages {
		if p == nil || p.Removed {
			continue
		}
		if p.TargetFile == file && p.Section == oldSection {
			p.Section = name
			changed++
		}
	}
	a.Message = fmt.Sprintf("category renamed for %d packages; press s to save", changed)
}

func (a *App) updateSelectedComment(text string) {
	p := a.selectedPackage()
	if p == nil {
		a.Message = "no package selected"
		return
	}
	p.Meta = strings.TrimSpace(text)
	a.Right = rightDetail
	a.Message = "comment updated in memory; press s to save"
}

func (a *App) jumpToPackageFile() {
	p := a.selectedPackage()
	if p == nil {
		a.Message = "no package selected"
		return
	}
	idx, _ := a.findAttrInOtherFile(p.Attr, p.TargetFile)
	if idx < 0 {
		a.Message = p.Attr + " not found in other files"
		return
	}
	a.FileCursor = idx
	a.SearchAll = false
	a.Filter = ""
	pkgs := a.Workspace.PackagesForFile(idx)
	for i, pkg := range pkgs {
		if pkg.Attr == p.Attr {
			a.PkgCursor = i
			break
		}
	}
	a.PkgOffset = 0
	a.ensureVisible()
	a.Message = "jumped to " + filepath.Base(a.Workspace.Files[idx].Path)
}

func (a *App) toggleFileImport() {
	if a.DefaultNixState == nil {
		a.Message = "no default.nix found"
		return
	}
	if a.FileCursor < 0 || a.FileCursor >= len(a.Workspace.Files) {
		return
	}
	base := a.Workspace.Files[a.FileCursor].BaseName()
	enabled, found := a.DefaultNixState.EnabledFor(base)
	if !found {
		a.Message = base + " not in default.nix imports"
		return
	}
	newEnabled := !enabled
	if err := defaultnix.SetEnabled(a.DefaultNixState.Path, base, newEnabled); err != nil {
		a.Message = "default.nix write failed: " + err.Error()
		return
	}
	if s, err := defaultnix.Parse(a.DefaultNixState.Path); err == nil {
		a.DefaultNixState = s
	}
	state := "disabled"
	if newEnabled {
		state = "enabled"
	}
	a.Message = base + " " + state + " in default.nix"
}

func (a *App) addFile(text string) {
	name := strings.TrimSpace(text)
	if name == "" {
		a.Message = "empty file name ignored"
		return
	}
	if !strings.HasSuffix(name, ".nix") {
		name += ".nix"
	}
	path := name
	if !filepath.IsAbs(path) {
		path = filepath.Join(save.WorkspaceDirectory(a.Workspace), name)
	}
	if _, err := os.Stat(path); err == nil {
		a.Message = "file already exists: " + filepath.Base(path)
		return
	} else if !os.IsNotExist(err) {
		a.Message = "file check failed: " + err.Error()
		return
	}
	content := "{ pkgs, ... }:\n{\n  environment.systemPackages = with pkgs; [\n  ];\n}\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		a.Message = "file create failed: " + err.Error()
		return
	}
	a.InputPaths = append(a.InputPaths, path)
	a.reloadWorkspace()
	if idx := a.Workspace.FileIndexByPath(path); idx >= 0 {
		a.FileCursor = idx
		a.PkgCursor = 0
		a.SearchAll = false
		a.ensureVisible()
	}
	a.Message = "file added: " + filepath.Base(path)
}

func (a *App) runNixSearch(keyword string) {
	keyword = strings.TrimSpace(keyword)
	if keyword == "" {
		a.Message = "empty nix-search keyword ignored"
		return
	}
	a.SwitchOutput = "running: nix-search -d " + keyword + "\n"
	a.SwitchTitle = "nix-search  " + keyword
	out, err := exec.Command("nix-search", "-d", keyword).CombinedOutput()
	a.SwitchOutput += string(out)
	if err != nil {
		a.SwitchOutput += "\nERROR: " + err.Error()
		a.Message = "nix-search failed"
		return
	}
	pkgs := parseNixSearchDetail(string(out))
	if len(pkgs) == 0 {
		a.Message = "nix-search returned no package attrs"
		return
	}
	path, err := a.writeNixSearchFile(keyword, pkgs)
	if err != nil {
		a.SwitchOutput += "\nERROR writing file: " + err.Error()
		a.Message = "nix-search file write failed"
		return
	}
	a.InputPaths = appendUniquePath(a.InputPaths, path)
	a.reloadWorkspace()
	if idx := a.Workspace.FileIndexByPath(path); idx >= 0 {
		a.FileCursor = idx
		a.PkgCursor = 0
		a.SearchAll = false
		a.ensureVisible()
	}
	a.Message = fmt.Sprintf("nix-search imported %d results into %s", len(pkgs), filepath.Base(path))
}

func (a *App) runNixFlakeSearch(keyword string) {
	keyword = strings.TrimSpace(keyword)
	if keyword == "" {
		a.Message = "empty nix search flake keyword ignored"
		return
	}
	a.SwitchOutput = "running: nix search nixpkgs " + keyword + "\n"
	a.SwitchTitle = "nix search nixpkgs  " + keyword
	cmd := exec.Command("nix", "search", "nixpkgs", keyword)
	cmd.Env = append(os.Environ(), "NO_COLOR=1")
	out, err := cmd.CombinedOutput()
	a.SwitchOutput += string(out)
	if err != nil {
		a.SwitchOutput += "\nERROR: " + err.Error()
		a.Message = "nix search flake failed"
		return
	}
	pkgs := parseNixFlakeSearch(string(out))
	if len(pkgs) == 0 {
		a.Message = "nix search flake returned no package attrs"
		return
	}
	path, err := a.writeNixFlakeSearchFile(keyword, pkgs)
	if err != nil {
		a.SwitchOutput += "\nERROR writing file: " + err.Error()
		a.Message = "nix search flake file write failed"
		return
	}
	a.InputPaths = appendUniquePath(a.InputPaths, path)
	a.reloadWorkspace()
	if idx := a.Workspace.FileIndexByPath(path); idx >= 0 {
		a.FileCursor = idx
		a.PkgCursor = 0
		a.SearchAll = false
		a.ensureVisible()
	}
	a.Message = fmt.Sprintf("nix search flake imported %d results into %s", len(pkgs), filepath.Base(path))
}

func (a App) writeNixFlakeSearchFile(keyword string, pkgs []nixPkg) (string, error) {
	name := "tuinix-flake-search-" + safeFileStem(keyword) + ".nix"
	path := filepath.Join(save.WorkspaceDirectory(a.Workspace), name)
	lines := []string{
		"{ pkgs, ... }:",
		"{",
		"  environment.systemPackages = with pkgs; [",
		"    # nix search flake: " + keyword,
	}
	for _, p := range pkgs {
		line := "    # " + p.Attr
		if p.Description != "" {
			line += " # " + p.Description
		}
		if p.Homepage != "" {
			line += " # " + p.Homepage
		}
		lines = append(lines, line)
	}
	lines = append(lines, "  ];", "}", "")
	return path, os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0o644)
}

var ansiEscapeRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripANSI(s string) string {
	return ansiEscapeRe.ReplaceAllString(s, "")
}

func parseNixFlakeSearch(output string) []nixPkg {
	output = stripANSI(output)
	seen := map[string]bool{}
	var pkgs []nixPkg
	lines := strings.Split(output, "\n")
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		if !strings.HasPrefix(line, "* ") {
			continue
		}
		rest := strings.TrimSpace(strings.TrimPrefix(line, "* "))
		attr := rest
		if idx := strings.LastIndex(attr, " ("); idx > 0 {
			attr = strings.TrimSpace(attr[:idx])
		}
		if strings.HasPrefix(attr, "legacyPackages.") || strings.HasPrefix(attr, "packages.") {
			attr = trimNixSearchAttr(attr)
		}
		if attr == "" || seen[attr] {
			continue
		}
		seen[attr] = true
		desc := ""
		if i+1 < len(lines) && strings.HasPrefix(lines[i+1], "  ") {
			desc = strings.TrimSpace(lines[i+1])
			i++
		}
		pkgs = append(pkgs, nixPkg{Attr: attr, Description: desc})
	}
	return pkgs
}

func (a App) writeNixSearchFile(keyword string, pkgs []nixPkg) (string, error) {
	name := "tuinix-search-" + safeFileStem(keyword) + ".nix"
	path := filepath.Join(save.WorkspaceDirectory(a.Workspace), name)
	lines := []string{
		"{ pkgs, ... }:",
		"{",
		"  environment.systemPackages = with pkgs; [",
		"    # nix-search: " + keyword,
	}
	for _, p := range pkgs {
		line := "    # " + p.Attr
		if p.Description != "" {
			line += " # " + p.Description
		}
		if p.Homepage != "" {
			line += " # " + p.Homepage
		}
		lines = append(lines, line)
	}
	lines = append(lines, "  ];", "}", "")
	return path, os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0o644)
}

type nixPkg struct {
	Attr        string
	Description string
	Homepage    string
}

func parseNixSearchDetail(output string) []nixPkg {
	seen := map[string]bool{}
	var pkgs []nixPkg
	var cur nixPkg
	flush := func() {
		if cur.Attr != "" && !seen[cur.Attr] {
			seen[cur.Attr] = true
			pkgs = append(pkgs, cur)
		}
		cur = nixPkg{}
	}
	for _, line := range strings.Split(output, "\n") {
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, " ") {
			trimmed := strings.TrimSpace(line)
			if val, ok := strings.CutPrefix(trimmed, "description: "); ok {
				cur.Description = val
			} else if val, ok := strings.CutPrefix(trimmed, "homepage: "); ok {
				cur.Homepage = val
			}
		} else {
			flush()
			attr := strings.TrimSpace(line)
			if strings.HasPrefix(attr, "legacyPackages.") {
				parts := strings.SplitN(attr, " ", 2)
				attr = trimNixSearchAttr(parts[0])
			} else if idx := strings.Index(attr, " @ "); idx > 0 {
				attr = attr[:idx]
			}
			cur.Attr = attr
		}
	}
	flush()
	return pkgs
}

func trimNixSearchAttr(s string) string {
	s = strings.Trim(s, " ,:")
	parts := strings.Split(s, ".")
	if len(parts) < 3 {
		return ""
	}
	return strings.Join(parts[2:], ".")
}

func safeFileStem(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	var b strings.Builder
	lastDash := false
	for _, r := range s {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		if ok {
			b.WriteRune(r)
			lastDash = false
			continue
		}
		if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		return "results"
	}
	return out
}

func appendUniquePath(paths []string, path string) []string {
	for _, p := range paths {
		if p == path {
			return paths
		}
	}
	return append(paths, path)
}

func (a *App) reloadWorkspace() {
	selectedAttr := ""
	selectedFile := ""
	if p := a.selectedPackage(); p != nil {
		selectedAttr = p.Attr
		selectedFile = p.TargetFile
	}
	w, err := parser.LoadWorkspace(a.InputPaths)
	if err != nil {
		a.Message = "reload failed: " + err.Error()
		return
	}
	a.Workspace = w
	a.Scripts = loadScripts(w)
	a.Context.Open = false
	a.Mode = modeNormal
	a.FileOffset = 0
	a.PkgOffset = 0
	if idx := w.FileIndexByPath(selectedFile); idx >= 0 {
		a.FileCursor = idx
	}
	a.PkgCursor = 0
	for i, p := range a.visiblePackages() {
		if p.TargetFile == selectedFile && p.Attr == selectedAttr {
			a.PkgCursor = i
			break
		}
	}
	if p := defaultnix.Find(a.InputPaths); p != "" {
		if s, err := defaultnix.Parse(p); err == nil {
			a.DefaultNixState = s
		}
	}
	a.ensureVisible()
	a.Message = "reloaded .nix files from disk"
}

func (a App) startNixosSwitch(runAfter bool) (App, tea.Cmd) {
	if a.SwitchRunning {
		a.Message = "nixos-rebuild switch already running"
		return a, nil
	}
	a.SwitchRunAfter = runAfter
	a.SwitchRunAttrs = nil
	if runAfter {
		a.SwitchRunAttrs = a.packagesToRunAfterSwitch()
	}
	if a.Workspace.Dirty() {
		a.Mode = modeSwitchConfirm
		a.Message = "unsaved changes before nixos-rebuild switch"
		return a, nil
	}
	return a.runNixosSwitch()
}

func (a App) runNixosSwitch() (App, tea.Cmd) {
	a.SwitchRunning = true
	a.SwitchOutput = ""
	a.SwitchTitle = "sudo nixos-rebuild switch"
	a.Message = "running sudo nixos-rebuild switch"
	dir := save.WorkspaceDirectory(a.Workspace)
	ch := make(chan switchStreamMsg, 32)
	a.SwitchStream = ch
	return a, tea.Batch(startNixosSwitchStream(dir, ch, a.SwitchRunAfter, a.SwitchRunAttrs), waitSwitchStream(ch))
}

func (a App) packagesToRunAfterSwitch() []string {
	seen := map[string]bool{}
	out := []string{}
	for _, p := range a.Workspace.Packages {
		if p == nil || p.Removed || !p.Enabled {
			continue
		}
		if !p.Added && p.OriginalEnabled {
			continue
		}
		attr := strings.TrimSpace(p.Attr)
		if attr == "" || seen[attr] {
			continue
		}
		seen[attr] = true
		out = append(out, attr)
	}
	return out
}

func startNixosSwitchStream(dir string, ch chan<- switchStreamMsg, runAfter bool, attrs []string) tea.Cmd {
	return func() tea.Msg {
		go runNixosSwitchStream(dir, ch, runAfter, attrs)
		return nil
	}
}

func waitSwitchStream(ch <-chan switchStreamMsg) tea.Cmd {
	return func() tea.Msg {
		msg, ok := <-ch
		if !ok {
			return switchStreamMsg{Done: true}
		}
		return msg
	}
}

func runNixosSwitchStream(dir string, ch chan<- switchStreamMsg, runAfter bool, attrs []string) {
	defer close(ch)
	cmd := exec.Command("sudo", "nixos-rebuild", "switch")
	cmd.Dir = dir
	ch <- switchStreamMsg{Text: "$ sudo nixos-rebuild switch\n"}
	if err := runStreamingCommand(cmd, ch); err != nil {
		ch <- switchStreamMsg{Err: err, Done: true}
		return
	}
	if runAfter {
		if len(attrs) == 0 {
			ch <- switchStreamMsg{Text: "\nNo new enabled packages to run.\n"}
		}
		for _, attr := range attrs {
			ch <- switchStreamMsg{Text: "\n$ " + attr + "\n"}
			cmd := exec.Command(attr)
			cmd.Dir = dir
			if err := runStreamingCommand(cmd, ch); err != nil {
				ch <- switchStreamMsg{Text: "ERROR running " + attr + ": " + err.Error() + "\n"}
			}
		}
	}
	ch <- switchStreamMsg{Done: true}
}

func runStreamingCommand(cmd *exec.Cmd, ch chan<- switchStreamMsg) error {
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go streamReader(stdout, ch, &wg)
	go streamReader(stderr, ch, &wg)
	wg.Wait()
	return cmd.Wait()
}

func streamReader(r io.Reader, ch chan<- switchStreamMsg, wg *sync.WaitGroup) {
	defer wg.Done()
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			ch <- switchStreamMsg{Text: string(buf[:n])}
		}
		if err != nil {
			return
		}
	}
}

func (a App) runSelectedScript() (App, tea.Cmd) {
	if len(a.Scripts) == 0 {
		a.Message = "no scripts found in ../scripts"
		return a, nil
	}
	if a.ScriptCursor < 0 || a.ScriptCursor >= len(a.Scripts) {
		a.ScriptCursor = 0
	}
	script := a.Scripts[a.ScriptCursor]
	a.Message = "running script: " + filepath.Base(script)
	cmd := exec.Command("sh", script)
	cmd.Dir = filepath.Dir(script)
	return a, tea.ExecProcess(cmd, func(err error) tea.Msg {
		return commandFinishedMsg{Attr: filepath.Base(script), Err: err}
	})
}

func loadScripts(w *model.Workspace) []string {
	dir := scriptsDirectory(w)
	matches, err := filepath.Glob(filepath.Join(dir, "*.sh"))
	if err != nil {
		return nil
	}
	return matches
}

func scriptsDirectory(w *model.Workspace) string {
	return filepath.Clean(filepath.Join(save.WorkspaceDirectory(w), "..", "scripts"))
}

func (a App) runSelectedPackageCommand() (App, tea.Cmd) {
	p := a.selectedPackage()
	if p == nil {
		a.Message = "no package selected"
		return a, nil
	}
	attr := strings.TrimSpace(p.Attr)
	if attr == "" {
		a.Message = "selected package has no command"
		return a, nil
	}
	if a.SwitchRunning {
		a.Message = "another command is already running"
		return a, nil
	}
	a.SwitchRunning = true
	a.SwitchOutput = ""
	a.SwitchTitle = attr
	a.Message = "running app: " + attr
	cmd := exec.Command(attr)
	cmd.Dir = save.WorkspaceDirectory(a.Workspace)
	ch := make(chan switchStreamMsg, 32)
	a.SwitchStream = ch
	return a, tea.Batch(startCommandStream(cmd, ch, "$ "+attr+"\n"), waitSwitchStream(ch))
}

func startCommandStream(cmd *exec.Cmd, ch chan<- switchStreamMsg, prefix string) tea.Cmd {
	return func() tea.Msg {
		go func() {
			defer close(ch)
			if prefix != "" {
				ch <- switchStreamMsg{Text: prefix}
			}
			ch <- switchStreamMsg{Err: runStreamingCommand(cmd, ch), Done: true}
		}()
		return nil
	}
}

func (a *App) saveWorkspace() {
	if err := a.saveWorkspaceWithReload(); err != nil {
		a.Message = "save failed: " + err.Error()
		return
	}
	a.Message = "saved with backups"
}

func (a *App) saveWorkspaceWithReload() error {
	oldFile := ""
	if a.FileCursor >= 0 && a.FileCursor < len(a.Workspace.Files) {
		oldFile = a.Workspace.Files[a.FileCursor].Path
	}
	if err := save.SaveAll(a.Workspace); err != nil {
		return err
	}
	w, err := parser.LoadWorkspace(a.InputPaths)
	if err != nil {
		return fmt.Errorf("saved, but reload failed: %w", err)
	}
	a.Workspace = w
	a.Scripts = loadScripts(w)
	if idx := w.FileIndexByPath(oldFile); idx >= 0 {
		a.FileCursor = idx
	}
	a.PkgCursor = 0
	a.FileOffset = 0
	a.PkgOffset = 0
	a.ensureVisible()
	return nil
}

func (a *App) initGit() {
	dir := save.WorkspaceDirectory(a.Workspace)
	out, err := gitctl.Init(dir)
	if err != nil {
		a.Message = "git init failed: " + err.Error()
	} else {
		a.Message = "git initialized"
	}
	a.Right = rightGit
	_ = out
}

func (a *App) commitGit() {
	dir := save.WorkspaceDirectory(a.Workspace)
	if !gitctl.IsRepo(dir) {
		a.Message = "not a git repo; press i to init"
		a.Right = rightGit
		return
	}
	if _, err := gitctl.CommitAll(dir, "tuinix: update packages"); err != nil {
		a.Message = "git commit failed: " + err.Error()
	} else {
		a.Message = "git commit created"
	}
	a.Right = rightGit
}

// View turns state into terminal text.  This is the one place where presentation
// is assembled; no mutation should happen here.
func (a App) View() string {
	if a.Width == 0 {
		a.Width = 120
	}
	if a.Height == 0 {
		a.Height = 40
	}
	leftW, midW := a.panelWidths()
	rightW := a.Width - leftW - midW - 2
	if rightW < 20 {
		rightW = 20
	}
	bodyH := a.bodyHeight()

	footer := a.renderFooter()
	header := a.renderHeader()
	left := a.renderLeftPanel(leftW, bodyH)
	mid := a.renderPackages(midW, bodyH)
	right := a.renderRight(rightW, bodyH)
	body := lipgloss.JoinHorizontal(lipgloss.Top, left, verticalRule(bodyH), mid, verticalRule(bodyH), right)
	if a.inputPopupActive() {
		body = a.renderInputPopup(bodyH)
	} else if a.Mode == modeSwitchConfirm {
		body = a.renderSwitchConfirmPopup(bodyH)
	} else if a.SwitchOutput != "" || a.SwitchRunning {
		body = a.renderSwitchOutputPopup(bodyH)
	}
	if a.ShowHelp {
		body = a.renderHelpPopup(bodyH)
	}
	if !a.FooterVisible {
		return body + "\n" + header
	}
	return footer + "\n" + body + "\n" + header
}

func (a App) renderHeader() string {
	dirty := ""
	if a.Workspace.Dirty() {
		dirty = " • unsaved"
	}
	gitState := "off"
	if gitctl.IsRepo(save.WorkspaceDirectory(a.Workspace)) {
		gitState = "on"
	}
	lines := []string{
		a.renderTitleLine("🅃 🅄 🄸 🅽 🅸 🆇 " + version + dirty),
	}
	if a.HeaderVisible {
		lines = append(lines,
			helpStyle.Render("git: "+gitState+" • root: "+save.WorkspaceDirectory(a.Workspace)+" • mouse: click • dbl-click toggle • right-click menu • p nix-search • F nix flake • n add pkg • N add cat • F2/r rename • F3/f find all • F4/c comment • F5/R reload • s save • S switch • q quit"),
		)
	} else {
		lines = append(lines, rule(a.Width))
	}
	return strings.Join(lines, "\n")
}

func (a App) renderTitleLine(title string) string {
	helpLabel := "[F1 Ajuda]"
	headerLabel := "[Header]"
	if !a.HeaderVisible {
		headerLabel = "[Header off]"
	}
	buttons := helpButtonStyle.Render(helpLabel) + " " + helpButtonStyle.Render(headerLabel)
	plainButtons := helpLabel + " " + headerLabel
	space := a.Width - utf8.RuneCountInString(title) - utf8.RuneCountInString(plainButtons)
	if space < 1 {
		return titleStyle.Render(clip(title, a.Width-1))
	}
	return buttons + strings.Repeat(" ", space) + titleStyle.Render(title)
}

func (a App) headerButtonColumns() (helpStart, helpEnd, footerStart, footerEnd int) {
	helpLabel := "[F1 Ajuda]"
	headerLabel := "[Header]"
	if !a.HeaderVisible {
		headerLabel = "[Header off]"
	}
	helpW := utf8.RuneCountInString(helpLabel)
	headerW := utf8.RuneCountInString(headerLabel)
	footerEnd = a.Width
	footerStart = footerEnd - headerW
	helpEnd = footerStart - 1
	helpStart = helpEnd - helpW
	return
}

func (a App) renderLeftPanel(width, height int) string {
	filesH, scriptsH := a.leftPanelHeights(height)
	files := a.renderFiles(width, filesH)
	if scriptsH <= 0 {
		return files
	}
	separator := mutedStyle.Render(rule(width))
	scripts := a.renderScripts(width, scriptsH)
	return files + "\n" + separator + "\n" + scripts
}

func (a App) renderFiles(width, height int) string {
	rows := make([]string, 0, height)
	offset := a.fileViewportOffset(height)
	for i := offset; i < len(a.Workspace.Files) && len(rows) < height; i++ {
		f := a.Workspace.Files[i]
		active, total := a.Workspace.EnabledCount(i)
		cursor := " "
		if i == a.FileCursor {
			cursor = "›"
		}
		importMark := " "
		importEnabled, importFound := a.DefaultNixState.EnabledFor(f.BaseName())
		if importFound {
			if importEnabled {
				importMark = "\u2713"
			} else {
				importMark = "\u2717"
			}
		}
		label := fmt.Sprintf("%s%s %-17s %d/%d", cursor, importMark, f.BaseName(), active, total)
		if i == a.FileCursor {
			label = selectedStyle.Render(clip(label, width-1))
		} else if importFound && importEnabled {
			label = importEnabledStyle.Render(clip(label, width-1))
		} else if importFound && !importEnabled {
			label = importDisabledStyle.Render(clip(label, width-1))
		} else {
			label = clip(label, width-1)
		}
		rows = append(rows, label)
	}
	if a.Context.Open && a.Context.Kind == contextKindFile {
		rows = a.renderContextMenuRows(rows, width)
	}
	return padBlock(rows, width, height)
}

func (a App) renderScripts(width, height int) string {
	rows := make([]string, 0, height)
	if height <= 0 {
		return ""
	}
	header := "Scripts ../scripts"
	if a.Focus == focusScripts {
		header = "› " + header
	} else {
		header = "  " + header
	}
	rows = append(rows, categoryStyle.Render(clip(header, width-1)))

	listH := scriptListHeight(height)
	offset := a.scriptViewportOffset(height)
	if len(a.Scripts) == 0 {
		rows = append(rows, mutedStyle.Render(clip("  no .sh files", width-1)))
	} else {
		for i := offset; i < len(a.Scripts) && len(rows) < 1+listH; i++ {
			cursor := " "
			if i == a.ScriptCursor {
				cursor = "›"
			}
			label := fmt.Sprintf("%s %-20s", cursor, filepath.Base(a.Scripts[i]))
			label = clip(label, width-1)
			if i == a.ScriptCursor && a.Focus == focusScripts {
				label = selectedStyle.Render(label)
			}
			rows = append(rows, label)
		}
	}
	for len(rows) < height-3 {
		rows = append(rows, "")
	}
	button := "[ Executar script ]"
	if a.Focus == focusScripts && len(a.Scripts) > 0 {
		button = selectedStyle.Render(clip(button, width-1))
	} else {
		button = contextMenuStyle.Render(clip(button, width-1))
	}
	rows = append(rows, button)
	switchButton := "[ Switch ]"
	if a.SwitchRunning {
		switchButton = "[ Switch rodando... ]"
	}
	rows = append(rows, renderRightButton(switchButton, width, a.Focus == focusScripts))
	rows = append(rows, renderRightButton("[ Switch and Run ]", width, a.Focus == focusScripts))
	return padBlock(rows, width, height)
}

func renderRightButton(label string, width int, selected bool) string {
	label = clip(label, width-1)
	pad := width - utf8.RuneCountInString(label) - 1
	if pad < 0 {
		pad = 0
	}
	line := strings.Repeat(" ", pad) + label
	if selected {
		return selectedStyle.Render(line)
	}
	return contextMenuStyle.Render(line)
}

func (a App) renderPackages(width, height int) string {
	rows := make([]string, 0, height)
	packageRows := a.packageRows()
	if len(packageRows) == 0 {
		rows = append(rows, mutedStyle.Render("No packages in this file/filter."))
	}
	offset := a.packageViewportOffset(height)
	for i := offset; i < len(packageRows) && len(rows) < height; i++ {
		row := packageRows[i]
		if row.Header {
			rows = append(rows, categoryStyle.Render(clip("Categoria: "+row.Section, width-1)))
			continue
		}
		line := a.renderPackageLine(len(rows), row.PackageIndex, row.Package, width)
		rows = append(rows, line)
	}
	for len(rows) < height {
		rows = append(rows, "")
	}
	if a.Context.Open && a.Context.Kind == contextKindPackage {
		rows = a.renderContextMenuRows(rows, width)
	}
	return padBlock(rows, width, height)
}

func (a App) renderPackageLine(visibleRow, packageIndex int, p *model.PackageEntry, width int) string {
	box := "[ ]"
	if p.Enabled {
		box = "[x]"
	}
	changed := " "
	if p.Changed() {
		changed = "*"
	}
	meta := p.DisplayMeta()
	if meta != "" {
		meta = " # " + meta
	}
	foundMark := "    "
	if idx, otherEnabled := a.findAttrInOtherFile(p.Attr, p.TargetFile); idx >= 0 {
		base := filepath.Base(a.Workspace.Files[idx].Path)
		short := base
		if len(short) > 7 {
			short = short[:6] + "…"
		}
		check := " "
		if otherEnabled {
			check = "x"
		}
		foundMark = mutedStyle.Render("[" + check + " " + short + "]")
	}
	line := fmt.Sprintf("%s%s %s %-24s%s", changed, foundMark, box, p.Attr, meta)
	line = clip(line, width-1)
	if packageIndex == a.PkgCursor && !a.contextMenuCoversRow(visibleRow) {
		line = selectedStyle.Render(line)
	}
	return line
}

func (a App) findAttrInOtherFile(attr, currentFile string) (fileIdx int, enabled bool) {
	for i, f := range a.Workspace.Files {
		if f.Path == currentFile {
			continue
		}
		for _, p := range f.Packages {
			if p != nil && !p.Removed && p.Attr == attr {
				return i, p.Enabled
			}
		}
	}
	return -1, false
}

func (a App) renderContextMenuRows(rows []string, width int) []string {
	labels := a.contextMenuLabels()
	for i, label := range labels {
		row := a.Context.Row + i
		if row < 0 || row >= len(rows) {
			continue
		}
		prefix := "  "
		if i == a.Context.Cursor {
			prefix = "› "
		}
		item := contextMenuStyle.Width(a.maxContextMenuWidth()).Render(prefix + label)
		rows[row] = overlay(rows[row], item, a.Context.Col, width)
	}
	return rows
}

func (a App) contextMenuCoversRow(row int) bool {
	if !a.Context.Open || a.Context.Kind != contextKindPackage {
		return false
	}
	return row >= a.Context.Row && row < a.Context.Row+len(a.contextMenuLabels())
}

func (a App) contextMenuLabels() []string {
	if a.Context.Kind == contextKindFile {
		return fileContextMenuLabels()
	}
	return packageContextMenuLabels()
}

func packageContextMenuLabels() []string {
	return []string{"Marcar/desmarcar", "Renomear", "Mover", "Alterar comentario", "Abrir app"}
}

func fileContextMenuLabels() []string {
	return []string{"Adicionar arquivo", "Add categoria"}
}

func contextMenuColumn(mouseX, leftW, midW, menuW int) int {
	col := mouseX - leftW
	if col < 0 {
		col = 0
	}
	if col+menuW > midW-1 {
		col = midW - menuW - 1
	}
	if col < 0 {
		return 0
	}
	return col
}

func (a App) contextActionAt(msg tea.MouseMsg) (contextAction, bool) {
	leftW, midW := a.panelWidths()
	top := a.topRows()
	row := msg.Y - top
	col := msg.X - leftW
	if a.Context.Kind == contextKindFile {
		col = msg.X
		if msg.X >= leftW {
			return 0, false
		}
	} else {
		if msg.X < leftW || msg.X >= leftW+midW {
			return 0, false
		}
	}
	if col < a.Context.Col {
		return 0, false
	}
	if col >= a.Context.Col+a.maxContextMenuWidth() {
		return 0, false
	}
	index := row - a.Context.Row
	if index < 0 || index >= len(a.contextMenuLabels()) {
		return 0, false
	}
	return contextAction(index), true
}

func (a App) maxContextMenuWidth() int {
	return maxLabelWidth(a.contextMenuLabels())
}

func maxLabelWidth(labels []string) int {
	width := 0
	for _, label := range labels {
		w := utf8.RuneCountInString(label) + 2
		if w > width {
			width = w
		}
	}
	return width
}

func overlay(base, over string, col, width int) string {
	if width <= 0 {
		return ""
	}
	baseRunes := []rune(lipgloss.NewStyle().Width(width).Render(base))
	if len(baseRunes) > width {
		baseRunes = baseRunes[:width]
	}
	for len(baseRunes) < width {
		baseRunes = append(baseRunes, ' ')
	}
	if col < 0 {
		col = 0
	}
	if col >= width {
		return string(baseRunes)
	}
	overRunes := []rune(over)
	if len(overRunes) > width-col {
		overRunes = overRunes[:width-col]
	}
	copy(baseRunes[col:], overRunes)
	return string(baseRunes)
}

func (a App) renderRight(width, height int) string {
	var lines []string
	switch a.Right {
	case rightDiff:
		lines = a.Workspace.DiffLines()
	case rightGit:
		dir := save.WorkspaceDirectory(a.Workspace)
		lines = []string{"Git", "===", "", gitctl.Status(dir), "", "Recent commits:", gitctl.Log(dir)}
	default:
		lines = a.packageDetails()
	}
	return padBlockWrapped(lines, width, height)
}

func (a App) inputPopupActive() bool {
	switch a.Mode {
	case modeSearch, modeNixSearch, modeNixFlakeSearch, modeAdd, modeAddCategory, modeAddFile, modeRename, modeComment:
		return true
	default:
		return false
	}
}

func (a App) inputPopupTitle() string {
	switch a.Mode {
	case modeSearch:
		return "Filtrar pacotes"
	case modeGlobalSearch:
		return "Pesquisar em todos os arquivos"
	case modeNixSearch:
		return "Pesquisar no nixpkgs"
	case modeNixFlakeSearch:
		return "Pesquisar flake nixpkgs"
	case modeAdd:
		return "Adicionar pacote"
	case modeAddCategory:
		return "Adicionar categoria"
	case modeAddFile:
		return "Adicionar arquivo .nix"
	case modeRename:
		return "Renomear"
	case modeComment:
		return "Alterar comentario"
	default:
		return "Entrada"
	}
}

func (a App) inputPopupLabel() string {
	switch a.Mode {
	case modeSearch:
		return "/"
	case modeGlobalSearch:
		return "buscar"
	case modeNixSearch:
		return "keyword"
	case modeNixFlakeSearch:
		return "flake keyword"
	case modeAdd:
		return "pacote"
	case modeAddCategory:
		return "categoria"
	case modeAddFile:
		return "arquivo"
	case modeRename:
		return "nome"
	case modeComment:
		return "comentario"
	default:
		return "valor"
	}
}

func (a App) renderInputPopup(height int) string {
	width := a.Width
	if width < 30 {
		width = 30
	}
	popupW := width - 8
	if popupW > 76 {
		popupW = 76
	}
	if popupW < 28 {
		popupW = 28
	}
	value := string(a.Input)
	if value == "" {
		value = " "
	}
	fieldW := popupW - 8
	if fieldW < 12 {
		fieldW = 12
	}
	field := inputFieldStyle.Width(fieldW).Render(clip(value+" ", fieldW-1))
	lines := []string{
		popupTitleStyle.Render(a.inputPopupTitle()),
		"",
		a.inputPopupLabel() + ": " + field,
		"",
		helpStyle.Render("Enter confirma • Esc cancela"),
	}
	box := popupStyle.Width(popupW).Render(strings.Join(lines, "\n"))
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, box)
}

func (a App) renderSwitchConfirmPopup(height int) string {
	text := strings.Join([]string{
		popupTitleStyle.Render("Alteracoes nao salvas"),
		"",
		"Existem alteracoes pendentes antes de executar:",
		commandStyle.Render("sudo nixos-rebuild switch"),
		"",
		"[s] salvar e executar    [n] executar sem salvar    [Esc] cancelar",
	}, "\n")
	return a.placePopup(height, text, 72)
}

func (a App) renderSwitchOutputPopup(height int) string {
	titleText := a.SwitchTitle
	if strings.TrimSpace(titleText) == "" {
		titleText = "comando"
	}
	title := "Output: " + titleText
	if a.SwitchRunning {
		title = "Executando: " + titleText
	}
	output := a.SwitchOutput
	if strings.TrimSpace(output) == "" && a.SwitchRunning {
		output = "aguardando output..."
	}
	lines := []string{
		popupTitleStyle.Render(title),
		"",
	}
	lines = append(lines, wrap(output, popupContentWidth(a.Width, 88))...)
	if a.SwitchRunning {
		lines = append(lines, "", helpStyle.Render("output em tempo real"))
	} else {
		lines = append(lines, "", helpStyle.Render("Enter/Esc fecha"))
	}
	return a.placePopup(height, strings.Join(limitPopupLines(lines, height), "\n"), 92)
}

func (a App) renderMessagePopup(height int, title, message string) string {
	text := strings.Join([]string{
		popupTitleStyle.Render(title),
		"",
		message,
	}, "\n")
	return a.placePopup(height, text, 64)
}

func (a App) renderHelpPopup(height int) string {
	lines := []string{
		popupTitleStyle.Render("Ajuda"),
		"",
		"F1 / ?       abrir ou fechar ajuda",
		"Topo         [Header] recolhe/expande o cabeçalho",
		"F12          mostrar/ocultar rodape",
		"Tab          alternar foco: arquivos, pacotes, scripts",
		"↑↓ / j k     mover cursor",
		"←→ / h l     trocar arquivo .nix",
		"Espaco/Enter marcar/desmarcar pacote",
		"",
		"n            adicionar pacote na categoria atual",
		"N            adicionar categoria",
		"p            nix-search  <keyword>",
		"F            nix search flake  <keyword>",
		"F2 / r       renomear pacote",
		"F3 / f       pesquisar em todos os arquivos",
		"Ctrl+F3      nix search flake  <keyword>",
		"F4 / c       alterar comentario",
		"F5 / R       recarregar arquivos .nix",
		"s            salvar",
		"S            sudo nixos-rebuild switch",
		"",
		"Mouse        clique seleciona, duplo clique alterna pacote",
		"Botao direito abre menu de contexto",
		"",
		"Enter/Esc fecha",
	}
	return a.placePopup(height, strings.Join(limitPopupLines(lines, height), "\n"), 82)
}

func (a App) placePopup(height int, content string, maxWidth int) string {
	width := a.Width
	if width < 30 {
		width = 30
	}
	popupW := width - 8
	if popupW > maxWidth {
		popupW = maxWidth
	}
	if popupW < 28 {
		popupW = 28
	}
	box := popupStyle.Width(popupW).Render(content)
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, box)
}

func popupContentWidth(totalWidth, maxPopupWidth int) int {
	w := totalWidth - 16
	if w > maxPopupWidth-8 {
		w = maxPopupWidth - 8
	}
	if w < 20 {
		w = 20
	}
	return w
}

func limitPopupLines(lines []string, bodyHeight int) []string {
	maxLines := bodyHeight - 6
	if maxLines < 5 {
		maxLines = 5
	}
	if len(lines) <= maxLines {
		return lines
	}
	out := append([]string{}, lines[:maxLines-2]...)
	out = append(out, "", helpStyle.Render("... output truncado no popup ..."))
	return out
}

func (a App) packageDetails() []string {
	p := a.selectedPackage()
	if p == nil {
		return []string{"No package selected."}
	}
	state := "disabled"
	if p.Enabled {
		state = "enabled"
	}
	out := []string{
		p.Attr,
		strings.Repeat("=", len(p.Attr)),
		"",
		"State: " + state,
		"Section: " + p.Section,
		"File: " + filepath.Base(p.TargetFile),
		"",
		"Comment:",
		p.DisplayMeta(),
		"",
		"NixOS Search:",
		nixos.SearchURL(p.Attr),
	}
	if strings.TrimSpace(p.DocMarkdown) != "" {
		out = append(out, "", "Docs:")
		out = append(out, renderPackageMarkdown(p.DocMarkdown)...)
	}
	return out
}

func renderPackageMarkdown(md string) []string {
	if cached, ok := markdownRenderCache[md]; ok {
		return cached
	}
	lines := renderMarkdownFallback(md)
	markdownRenderCache[md] = lines
	return lines
}

func renderMarkdownFallback(md string) []string {
	out := []string{}
	inCode := false
	codeBuf := []string{}
	for _, line := range strings.Split(md, "\n") {
		s := strings.TrimSpace(line)
		if strings.HasPrefix(s, "```") {
			if inCode {
				out = append(out, renderCodeBlock(codeBuf)...)
				codeBuf = nil
			}
			inCode = !inCode
			continue
		}
		if inCode {
			codeBuf = append(codeBuf, line)
			continue
		}
		switch {
		case strings.HasPrefix(s, "#"):
			s = strings.TrimSpace(strings.TrimLeft(s, "#"))
			if s != "" {
				out = append(out, markdownHeadingStyle.Render(renderInlineMarkdown(s)))
			}
		case strings.HasPrefix(s, "- "), strings.HasPrefix(s, "* "):
			out = append(out, "  • "+renderInlineMarkdown(strings.TrimSpace(s[2:])))
		case s == "":
			out = append(out, "")
		default:
			out = append(out, renderInlineMarkdown(line))
		}
	}
	if inCode && len(codeBuf) > 0 {
		out = append(out, renderCodeBlock(codeBuf)...)
	}
	return out
}

func renderCodeBlock(lines []string) []string {
	out := make([]string, 0, len(lines)+2)
	out = append(out, markdownFenceStyle.Render("  ```"))
	for _, line := range lines {
		out = append(out, markdownCodeStyle.Render("  "+line))
	}
	out = append(out, markdownFenceStyle.Render("  ```"))
	return out
}

func renderInlineMarkdown(s string) string {
	s = renderMarkdownLinks(s)
	s = renderMarkdownCodeSpans(s)
	s = renderMarkdownBold(s)
	return s
}

func renderMarkdownLinks(s string) string {
	for {
		start := strings.Index(s, "[")
		if start < 0 {
			return s
		}
		mid := strings.Index(s[start:], "](")
		if mid < 0 {
			return s
		}
		mid += start
		end := strings.Index(s[mid+2:], ")")
		if end < 0 {
			return s
		}
		end += mid + 2
		text := s[start+1 : mid]
		url := s[mid+2 : end]
		s = s[:start] + text + " (" + url + ")" + s[end+1:]
	}
}

func renderMarkdownCodeSpans(s string) string {
	for {
		start := strings.Index(s, "`")
		if start < 0 {
			return s
		}
		end := strings.Index(s[start+1:], "`")
		if end < 0 {
			return s
		}
		end += start + 1
		s = s[:start] + markdownCodeSpanStyle.Render(s[start+1:end]) + s[end+1:]
	}
}

func renderMarkdownBold(s string) string {
	for {
		start := strings.Index(s, "**")
		if start < 0 {
			return s
		}
		end := strings.Index(s[start+2:], "**")
		if end < 0 {
			return s
		}
		end += start + 2
		s = s[:start] + markdownBoldStyle.Render(s[start+2:end]) + s[end+2:]
	}
}

func (a App) renderFooter() string {
	prompt := ""
	switch a.Mode {
	case modeSearch:
		prompt = "/" + string(a.Input) + "█"
	case modeGlobalSearch:
		prompt = "buscar: " + string(a.Input) + "█"
	case modeNixSearch:
		prompt = "typing nixpkgs keyword"
	case modeNixFlakeSearch:
		prompt = "typing nix search flake keyword"
	case modeAdd:
		prompt = "typing package"
	case modeAddCategory:
		prompt = "typing category"
	case modeAddFile:
		prompt = "typing file"
	case modeMove:
		name := ""
		if a.MoveCursor >= 0 && a.MoveCursor < len(a.Workspace.Files) {
			name = a.Workspace.Files[a.MoveCursor].BaseName()
		}
		prompt = "move target: " + name + "  (↑↓ choose, Enter confirm, Esc cancel)"
	case modeRename:
		prompt = "typing rename"
	case modeComment:
		prompt = "typing comment"
	default:
		prompt = a.Message
	}
	button := helpButtonStyle.Render("[F12 Rodape]")
	if !a.FooterVisible {
		button = helpButtonStyle.Render("[F12 Rodape off]")
	}
	_, buttonEnd := a.footerButtonColumns()
	space := buttonEnd - utf8.RuneCountInString(prompt) - utf8.RuneCountInString(button)
	if space < 1 {
		space = 1
	}
	line := prompt + strings.Repeat(" ", space) + button
	return rule(a.Width) + "\n" + statusStyle.Width(a.Width).Render(line)
}

func (a App) panelWidths() (int, int) {
	left := 30
	mid := a.Width/2 - 2
	if mid < 40 {
		mid = 40
	}
	if left+mid > a.Width-25 {
		mid = a.Width - left - 25
	}
	return left, mid
}

func (a App) topRows() int {
	if a.FooterVisible {
		return 2
	}
	return 0
}

func (a App) leftPanelHeights(height int) (int, int) {
	if height < 7 {
		return height, 0
	}
	scripts := height / 3
	if scripts < 5 {
		scripts = 5
	}
	if scripts > height-4 {
		scripts = height - 4
	}
	files := height - scripts - 1
	if files < 3 {
		files = 3
		scripts = height - files - 1
	}
	return files, scripts
}

func scriptListHeight(panelHeight int) int {
	h := panelHeight - 4
	if h < 1 {
		return 1
	}
	return h
}

func (a App) bodyHeight() int {
	bodyH := a.Height - a.topRows() - 2
	if bodyH < 5 {
		bodyH = 5
	}
	return bodyH
}

var (
	markdownRenderCache = map[string][]string{}

	titleStyle            = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("9"))
	helpStyle             = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	mutedStyle            = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	selectedStyle         = lipgloss.NewStyle().Background(lipgloss.Color("12")).Foreground(lipgloss.Color("0"))
	categoryStyle         = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("14"))
	popupStyle            = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.Color("14")).Padding(1, 2)
	popupTitleStyle       = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("14"))
	inputFieldStyle       = lipgloss.NewStyle().Foreground(lipgloss.Color("0")).Background(lipgloss.Color("15"))
	commandStyle          = lipgloss.NewStyle().Foreground(lipgloss.Color("15")).Background(lipgloss.Color("8")).Padding(0, 1)
	helpButtonStyle       = lipgloss.NewStyle().Foreground(lipgloss.Color("0")).Background(lipgloss.Color("14"))
	markdownHeadingStyle  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("14"))
	markdownBoldStyle     = lipgloss.NewStyle().Bold(true)
	markdownCodeStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("11"))
	markdownCodeSpanStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("11")).Background(lipgloss.Color("8"))
	markdownFenceStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	contextMenuStyle      = lipgloss.NewStyle().
				Foreground(lipgloss.Color("0")).
				Background(lipgloss.Color("15"))
	statusStyle          = lipgloss.NewStyle().Foreground(lipgloss.Color("15")).Background(lipgloss.Color("12"))
	importEnabledStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("10"))
	importDisabledStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
)

func rule(width int) string {
	if width < 1 {
		width = 1
	}
	return strings.Repeat("─", width)
}

func verticalRule(height int) string {
	rows := make([]string, height)
	for i := range rows {
		rows[i] = "│"
	}
	return strings.Join(rows, "\n")
}

func padBlock(rows []string, width, height int) string {
	out := make([]string, height)
	for i := 0; i < height; i++ {
		line := ""
		if i < len(rows) {
			line = rows[i]
		}
		out[i] = lipgloss.NewStyle().Width(width).Render(line)
	}
	return strings.Join(out, "\n")
}

func padBlockWrapped(lines []string, width, height int) string {
	rows := []string{}
	for _, line := range lines {
		for _, part := range wrap(line, width-1) {
			rows = append(rows, part)
		}
	}
	return padBlock(rows, width, height)
}

func wrap(s string, width int) []string {
	if width <= 0 {
		return []string{s}
	}
	if s == "" {
		return []string{""}
	}
	runes := []rune(s)
	out := []string{}
	for len(runes) > width {
		out = append(out, string(runes[:width]))
		runes = runes[width:]
	}
	out = append(out, string(runes))
	return out
}

func clip(s string, width int) string {
	if width <= 0 {
		return ""
	}
	if utf8.RuneCountInString(s) <= width {
		return s
	}
	r := []rune(s)
	if width <= 1 {
		return string(r[:width])
	}
	return string(r[:width-1]) + "…"
}
