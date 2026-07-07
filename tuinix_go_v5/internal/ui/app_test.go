package ui

import (
	"strings"
	"testing"
)

func TestRenderMarkdownFallback(t *testing.T) {
	md := "# Title\n\nUse **bold**, `code` and [OpenAI](https://openai.com).\n\n- item one\n* item two\n\n```go\nfmt.Println(\"hi\")\n```\n"
	lines := renderMarkdownFallback(md)
	got := strings.Join(lines, "\n")
	for _, want := range []string{
		"Title",
		"bold",
		"code",
		"OpenAI (https://openai.com)",
		"• item one",
		"• item two",
		"fmt.Println(\"hi\")",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("expected %q in rendered markdown, got:\n%s", want, got)
		}
	}
}
