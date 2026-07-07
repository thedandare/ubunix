# TUINIX architecture

TUINIX is organized as a small terminal application with a strict separation between parsing, state, saving, Git integration, external NixOS package search, and the Bubble Tea UI.

The parser reads Nix files and converts package lines inside `environment.systemPackages` into an in-memory workspace. The model layer owns mutations such as toggling, adding, and moving packages. The save layer renders the mutated workspace back into `.nix` files while preserving unrelated lines. The UI layer is a Bubble Tea state machine that turns keyboard and mouse events into model operations. Git integration is deliberately implemented as a thin wrapper around the local `git` executable.

The code comments are the primary documentation. They explain Go syntax, design choices, and the mapping from familiar Dart concepts to Go constructs.
