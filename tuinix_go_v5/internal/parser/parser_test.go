package parser

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseCommentedPackagesBeforeSections(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "dns.nix")
	content := `{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    #▐ 🄳🄽🅂 Core Clients / Diagnostics ▌
    # dnsx # Fast and multi-purpose DNS toolkit
    # gnuradioPackages.osmosdr
    dnsperf # Benchmark DNS performance
    #                 # continuation comment must not become a package
  ];
}
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	counter := 0
	_, pkgs, err := ParseFile(path, &counter)
	if err != nil {
		t.Fatal(err)
	}
	if len(pkgs) != 3 {
		t.Fatalf("expected 3 packages, got %d: %#v", len(pkgs), pkgs)
	}
	if pkgs[0].Attr != "dnsx" || pkgs[0].Enabled {
		t.Fatalf("expected dnsx disabled, got %+v", pkgs[0])
	}
	if pkgs[1].Attr != "gnuradioPackages.osmosdr" || pkgs[1].Enabled {
		t.Fatalf("expected gnuradioPackages.osmosdr disabled, got %+v", pkgs[1])
	}
	if pkgs[2].Attr != "dnsperf" || !pkgs[2].Enabled {
		t.Fatalf("expected dnsperf enabled, got %+v", pkgs[2])
	}
}

func TestParseBoxBannerAsCategory(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cloud.nix")
	content := `{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    #▐▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▌
    #▐ ☁️ Google Cloud / Android                                   ▌
    #▐ Google Cloud CLI tooling, GCE support and Android SDK.      ▌
    #▐▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▌
    google-cloud-sdk
    android-tools
  ];
}
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	counter := 0
	_, pkgs, err := ParseFile(path, &counter)
	if err != nil {
		t.Fatal(err)
	}
	if len(pkgs) != 2 {
		t.Fatalf("expected 2 packages, got %d: %#v", len(pkgs), pkgs)
	}
	for _, pkg := range pkgs {
		if pkg.Section != "☁️ Google Cloud / Android" {
			t.Fatalf("expected banner title category, got %q for %+v", pkg.Section, pkg)
		}
	}
}

func TestParseMarkdownBlockBelowPackage(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "docs.nix")
	content := `{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    ripgrep # fast search
    /*
    # Ripgrep notes

    - uses regex
    - respects gitignore
    */
    fd
  ];
}
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	counter := 0
	_, pkgs, err := ParseFile(path, &counter)
	if err != nil {
		t.Fatal(err)
	}
	if len(pkgs) != 2 {
		t.Fatalf("expected 2 packages, got %d: %#v", len(pkgs), pkgs)
	}
	if pkgs[0].Attr != "ripgrep" {
		t.Fatalf("expected ripgrep first, got %+v", pkgs[0])
	}
	if pkgs[0].DocMarkdown == "" || !strings.Contains(pkgs[0].DocMarkdown, "Ripgrep notes") {
		t.Fatalf("expected markdown doc block, got %q", pkgs[0].DocMarkdown)
	}
	if pkgs[1].Attr != "fd" {
		t.Fatalf("expected fd second, got %+v", pkgs[1])
	}
}
