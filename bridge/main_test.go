package main

import "testing"

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
