package main

import "testing"

func TestSkipHooks(t *testing.T) {
	if !skipHooks("1") {
		t.Error("ATOLL_SKIP_HOOKS=1 should opt the run out")
	}
	for _, v := range []string{"", "0", "true", "yes"} {
		if skipHooks(v) {
			t.Errorf("ATOLL_SKIP_HOOKS=%q should not opt out", v)
		}
	}
}

func TestParseEndpoint(t *testing.T) {
	port, token, host := parseEndpoint("ATOLL_PORT=51936\nATOLL_TOKEN=abc123\n")
	if port != "51936" || token != "abc123" || host != "" {
		t.Errorf("got port=%q token=%q host=%q", port, token, host)
	}
}

func TestParseEndpointWithHostAndWhitespace(t *testing.T) {
	port, token, host := parseEndpoint("  ATOLL_PORT=8080 \n\nATOLL_HOST=box.local\nATOLL_TOKEN=t\n")
	if port != "8080" || token != "t" || host != "box.local" {
		t.Errorf("got port=%q token=%q host=%q", port, token, host)
	}
}

func TestParseEndpointSkipsMalformedAndUnknownLines(t *testing.T) {
	port, token, host := parseEndpoint("garbage line\nATOLL_PORT=1\nFOO=bar\n=noKey\n")
	if port != "1" || token != "" || host != "" {
		t.Errorf("malformed/unknown lines should be ignored: port=%q token=%q host=%q", port, token, host)
	}
}

func TestParseEndpointEmpty(t *testing.T) {
	port, token, host := parseEndpoint("")
	if port != "" || token != "" || host != "" {
		t.Errorf("empty input should yield empty fields, got port=%q token=%q host=%q", port, token, host)
	}
}

func TestURLEncode(t *testing.T) {
	tests := map[string]string{
		"plain-_.~": "plain-_.~",
		"a b":       "a%20b",
		"a/b?c":     "a%2Fb%3Fc",
		"珊瑚":        "%E7%8F%8A%E7%91%9A",
	}
	for input, want := range tests {
		if got := urlEncode(input); got != want {
			t.Errorf("urlEncode(%q) = %q, want %q", input, got, want)
		}
	}
}
