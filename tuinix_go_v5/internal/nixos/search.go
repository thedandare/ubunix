// Package nixos builds NixOS Search URLs and opens them.
package nixos

import (
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"runtime"
)

func SearchURL(pkg string) string {
	channel := os.Getenv("TUINIX_NIXOS_CHANNEL")
	if channel == "" {
		channel = "26.05"
	}
	buckets := `{%22package_attr_set%22:[%22No+package+set%22],%22package_license_set%22:[],%22package_maintainers_set%22:[],%22package_teams_set%22:[],%22package_platforms%22:[]}`
	return fmt.Sprintf("https://search.nixos.org/packages?buckets=%s&channel=%s&query=%s", buckets, url.QueryEscape(channel), url.QueryEscape(pkg))
}

func OpenSearch(pkg string) error {
	u := SearchURL(pkg)
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", u)
	default:
		cmd = exec.Command("xdg-open", u)
	}
	return cmd.Start()
}
