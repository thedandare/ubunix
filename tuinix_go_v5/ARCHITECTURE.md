# TUINIX solution architecture

`cmd/tuinix` is the executable entry point. It resolves input paths, loads a workspace, starts the Bubble Tea program, and keeps `main` small.

`internal/parser` detects `environment.systemPackages` blocks and classifies lines as active package, commented package, section header, or ignored comment. It intentionally uses a conservative line-oriented parser rather than a full Nix AST, because TUINIX edits package-list style files and must preserve hand-written layout.

`internal/model` stores files, packages, cursor-independent identity, original locations, target locations, and dirty state. It is UI-agnostic.

`internal/save` turns the model back into files. It replaces original package lines, removes moved lines from their source file, inserts new or moved packages before the closing bracket of the target package list, and creates backups.

`internal/ui` is a Bubble Tea state machine. It owns focus, search mode, add mode, move mode, diff mode, and rendering.

`internal/gitctl` treats Git as an external persistence layer for the directory being edited.

`internal/nixos` builds NixOS Search URLs and opens them with the desktop opener.
