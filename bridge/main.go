// atoll-bridge: hook shim between agent CLIs and the Atoll app.
// Reads the hook payload from stdin, forwards it to the local gateway,
// and prints the gateway's decision (if any) to stdout.
// Always exits 0: agent sessions must never be broken by Atoll's absence.
package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const version = "0.1.0"

func main() {
	source := "claude"
	hold := false
	for i, a := range os.Args[1:] {
		if a == "--source" && i+2 <= len(os.Args)-1 {
			source = os.Args[i+2]
		}
		if a == "--hold" {
			hold = true
		}
	}

	payload, err := io.ReadAll(io.LimitReader(os.Stdin, 4<<20))
	if err != nil || len(payload) == 0 {
		return
	}

	port, token := readEndpoint()
	if port == "" || token == "" {
		return
	}

	body := map[string]string{
		"v":       "1",
		"bridge":  version,
		"source":  source,
		"tty":     ttyName(),
		"pid":     fmt.Sprintf("%d", os.Getppid()),
		"cwd":     cwd(),
		"payload": string(payload),
	}
	if hold {
		body["hold"] = "1"
	}
	// Explicit per-request override for diagnostics and advanced hook setups.
	// Normal installed hooks leave this unset and use the App's per-agent policy.
	if route := os.Getenv("ATOLL_APPROVAL_ROUTE"); route == "atoll" || route == "native" {
		body["approval_route"] = route
	}
	// Set by the SSH deploy script; tags the session as running on a remote host.
	if host := os.Getenv("ATOLL_HOST"); host != "" {
		body["host"] = host
	}
	var buf bytes.Buffer
	first := true
	for k, v := range body {
		if !first {
			buf.WriteByte('&')
		}
		first = false
		buf.WriteString(urlEncode(k))
		buf.WriteByte('=')
		buf.WriteString(urlEncode(v))
	}

	// Hold mode: no client timeout — the gateway keeps the connection open until
	// the user decides. If the app dies, the TCP close errors out client.Do and
	// we exit silently, letting the CLI fall back to its native permission flow.
	// The hook-level timeout in settings.json is the hard upper bound.
	timeout := 3 * time.Second
	if hold {
		timeout = 0
	}
	client := &http.Client{Timeout: timeout}
	req, err := http.NewRequest("POST", "http://127.0.0.1:"+port+"/hook/"+source, &buf)
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("X-Atoll-Token", token)
	resp, err := client.Do(req)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	// A non-empty 200 response is a hook decision the CLI should see.
	if resp.StatusCode == http.StatusOK && len(bytes.TrimSpace(out)) > 0 {
		os.Stdout.Write(out)
	}
}

// readEndpoint parses ~/.atoll/run/endpoint (KEY=VALUE lines).
// On a remote host the deploy script writes ATOLL_HOST plus a tunnel port.
// parseEndpoint extracts the port, token and optional host from the endpoint
// file's contents. Pure (no filesystem/env), so it is unit-testable.
func parseEndpoint(data string) (port, token, host string) {
	for _, line := range strings.Split(data, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		switch k {
		case "ATOLL_PORT":
			port = v
		case "ATOLL_TOKEN":
			token = v
		case "ATOLL_HOST":
			host = v
		}
	}
	return
}

func readEndpoint() (port, token string) {
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	data, err := os.ReadFile(filepath.Join(home, ".atoll", "run", "endpoint"))
	if err != nil {
		return
	}
	var host string
	port, token, host = parseEndpoint(string(data))
	if host != "" {
		os.Setenv("ATOLL_HOST", host)
	}
	return
}

// ttyName walks up the process tree looking for an ancestor with a controlling
// tty (the agent CLI in its terminal). Hook helpers themselves have none.
func ttyName() string {
	pid := os.Getppid()
	for hop := 0; hop < 6 && pid > 1; hop++ {
		out, err := exec.Command("ps", "-o", "tty=,ppid=", "-p", fmt.Sprintf("%d", pid)).Output()
		if err != nil {
			return ""
		}
		fields := strings.Fields(string(out))
		if len(fields) < 2 {
			return ""
		}
		if fields[0] != "??" && fields[0] != "" {
			return "/dev/" + fields[0]
		}
		next, err := strconv.Atoi(fields[1])
		if err != nil {
			return ""
		}
		pid = next
	}
	return ""
}

func cwd() string {
	d, _ := os.Getwd()
	return d
}

func urlEncode(s string) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '-', c == '_', c == '.', c == '~':
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
