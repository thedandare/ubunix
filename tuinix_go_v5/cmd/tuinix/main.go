// Command tuinix starts the TUINIX terminal package manager.
//
// This file is intentionally small.  In Go, main packages are just entry
// points; application logic belongs in normal packages under internal/.
//
// Dart analogy:
//
//	void main(List<String> args) { runApp(...); }
//
// Here:
//
//	func main() { tea.NewProgram(...).Run() }
package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"

	"tuinix/internal/gitctl"
	"tuinix/internal/parser"
	"tuinix/internal/save"
	"tuinix/internal/ui"
)

func main() {
	inputPaths := os.Args[1:]
	workspace, err := parser.LoadWorkspace(inputPaths)
	if err != nil {
		fmt.Fprintln(os.Stderr, "tuinix:", err)
		os.Exit(1)
	}

	if os.Getenv("TUINIX_GIT_AUTO_INIT") == "1" {
		dir := save.WorkspaceDirectory(workspace)
		if !gitctl.IsRepo(dir) {
			_, _ = gitctl.Init(dir)
		}
	}

	program := tea.NewProgram(
		ui.New(workspace, inputPaths),
		tea.WithAltScreen(),
		tea.WithMouseCellMotion(),
	)

	if _, err := program.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "tuinix:", err)
		os.Exit(1)
	}
}
