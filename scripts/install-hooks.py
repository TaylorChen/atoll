#!/usr/bin/env python3
"""Install Atoll integrations for supported agent tools (non-destructive, idempotent).

- Appends atoll-fingerprinted hook entries alongside existing ones; never touches
  entries owned by other tools.
- Backs up existing configuration before each modification.
- `--remove` strips all atoll entries and nothing else.
"""
import json
import shutil
import sys
import time
from pathlib import Path

FINGERPRINT = ".atoll/"
BRIDGE_PATH = Path.home() / ".atoll" / "bin" / "atoll-bridge"
BRIDGE = str(BRIDGE_PATH)

def cmd(source: str, hold: bool = False) -> str:
    # Invoke the bridge binary directly, UNQUOTED. Desktop agents
    # (Codex/Qoder) don't shell-parse the command — a quoted path becomes a
    # literal filename they can't find. Path has no spaces, so quotes are unneeded.
    return f"{BRIDGE} --source {source}" + (" --hold" if hold else "")

# Per-CLI configs: (event, matcher-or-None, timeout, hold).
# Monitoring hooks are short; approval hooks hold the connection while the
# user decides in the Atoll panel (bridge exits early if the app dies).
CONFIGS = {
    "claude": {
        "path": Path.home() / ".claude" / "settings.json",
        "specs": [
            ("PreToolUse", "*", 10, False),
            ("PostToolUse", "*", 10, False),
            ("PostToolUseFailure", "*", 10, False),
            ("SessionStart", None, 10, False),
            ("UserPromptSubmit", None, 10, False),
            ("PreCompact", None, 10, False),
            ("Stop", None, 10, False),
            ("StopFailure", None, 10, False),
            ("SubagentStart", None, 10, False),
            ("SubagentStop", None, 10, False),
            ("SessionEnd", None, 10, False),
            ("PermissionRequest", "*", 3600, True),
            ("PreToolUse", "AskUserQuestion", 3600, True),
        ],
    },
    "codex": {
        "path": Path.home() / ".codex" / "hooks.json",
        "specs": [
            ("PreToolUse", "*", 10, False),
            ("PostToolUse", "*", 10, False),
            ("SessionStart", None, 10, False),
            ("UserPromptSubmit", None, 10, False),
            ("Stop", None, 10, False),
            ("SubagentStop", None, 10, False),
            ("PermissionRequest", "*", 3600, True),
        ],
    },
    # Only events proven safe on this machine's gemini version (Orca uses the same).
    "gemini": {
        "path": Path.home() / ".gemini" / "settings.json",
        "specs": [
            ("BeforeAgent", None, 10, False),
            ("AfterAgent", None, 10, False),
        ],
    },
    # Qoder mirrors the Claude hook format (PascalCase events + nested hooks).
    # QoderWork (desktop, Electron ~0.9.12) parses and normalizes a hooks config
    # but does NOT execute external hook commands — verified with a plain-shell
    # canary that never fired after a full app restart. It also rewrites the file
    # on launch, keeping only the events it recognizes (SessionStart/Stop/
    # SessionEnd) and stripping the rest. We install only those 3 to avoid config
    # churn; monitoring is effectively unavailable until QoderWork wires hook
    # execution (surfaced to the user via AgentCatalog.note).
    "qoder": {
        "path": Path.home() / ".qoder" / "settings.json",
        "specs": [
            ("SessionStart", None, 10, False),
            ("Stop", None, 10, False),
            ("SessionEnd", None, 10, False),
        ],
    },
    # Claude-compatible agents use the same hook payload and response schema,
    # but keep distinct source IDs so Atoll can present and evolve them safely.
    "qwen": {
        "path": Path.home() / ".qwen" / "settings.json",
        "specs": [],
    },
    "factory": {
        "path": Path.home() / ".factory" / "settings.json",
        "specs": [],
    },
    "codebuddy": {
        "path": Path.home() / ".codebuddy" / "settings.json",
        "specs": [],
    },
    # Cursor uses a FLAT hook format (camelCase events, {command,timeout} entries).
    "cursor": {
        "path": Path.home() / ".cursor" / "hooks.json",
        "flat": True,
        "specs": [
            ("beforeSubmitPrompt", None, 10, False),
            ("preToolUse", None, 10, False),
            ("postToolUse", None, 10, False),
            ("afterFileEdit", None, 10, False),
            ("afterShellExecution", None, 10, False),
            ("stop", None, 10, False),
            ("subagentStart", None, 10, False),
            ("subagentStop", None, 10, False),
        ],
    },
}

# The common, verified Claude-compatible lifecycle. Defined once after CONFIGS
# to avoid silently drifting one fork away from the others.
CLAUDE_FORK_SPECS = [
    ("PreToolUse", "*", 10, False),
    ("PostToolUse", "*", 10, False),
    ("PostToolUseFailure", "*", 10, False),
    ("SessionStart", None, 10, False),
    ("UserPromptSubmit", None, 10, False),
    ("Stop", None, 10, False),
    ("SubagentStop", None, 10, False),
    ("SessionEnd", None, 10, False),
    ("PermissionRequest", "*", 3600, True),
]
for _source in ("qwen", "factory", "codebuddy"):
    CONFIGS[_source]["specs"] = CLAUDE_FORK_SPECS

KIMI_PATH = Path.home() / ".kimi" / "config.toml"
KIMI_MARKER = "# atoll: managed hook — do not edit"
KIMI_EVENTS = [
    ("SessionStart", "startup|resume"),
    ("UserPromptSubmit", None),
    ("Stop", None),
    ("Notification", None),
    ("PreToolUse", None),
    ("PostToolUse", None),
]
OPENCODE_DIR = Path.home() / ".config" / "opencode"
OPENCODE_PLUGIN = OPENCODE_DIR / "plugins" / "atoll.js"
OPENCODE_ASSET = Path(__file__).with_name("atoll-opencode.js")
ENABLED_FILE = Path.home() / ".atoll" / "cache" / "enabled-integrations.json"


def opencode_config_path() -> Path:
    modern = OPENCODE_DIR / "opencode.json"
    return modern if modern.exists() else OPENCODE_DIR / "config.json"


def integration_installed(source: str) -> bool:
    if source in CONFIGS:
        path = CONFIGS[source]["path"]
        if not path.exists():
            return False
        hooks = json.loads(path.read_text()).get("hooks", {})
        return any(is_atoll(entry) for entries in hooks.values() for entry in entries)
    if source == "kimi":
        return KIMI_PATH.exists() and KIMI_MARKER in KIMI_PATH.read_text()
    if source == "opencode":
        path = opencode_config_path()
        if not path.exists() or not OPENCODE_PLUGIN.exists():
            return False
        return f"file://{OPENCODE_PLUGIN}" in json.loads(path.read_text()).get("plugin", [])
    return False


def enabled_integrations() -> set[str]:
    if ENABLED_FILE.exists():
        return set(json.loads(ENABLED_FILE.read_text()))
    # Upgrade path: record the integrations already installed by an older Atoll
    # before the watcher attempts any restoration.
    sources = list(CONFIGS) + ["kimi", "opencode"]
    enabled = {source for source in sources if integration_installed(source)}
    ENABLED_FILE.parent.mkdir(parents=True, exist_ok=True)
    ENABLED_FILE.write_text(json.dumps(sorted(enabled), indent=2) + "\n")
    return enabled


def record_enabled(source: str, enabled: bool) -> None:
    sources = enabled_integrations()
    if enabled:
        sources.add(source)
    else:
        sources.discard(source)
    ENABLED_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = ENABLED_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(sorted(sources), indent=2) + "\n")
    tmp.replace(ENABLED_FILE)


def is_atoll(entry: dict) -> bool:
    # Nested (Claude-style) entry has a "hooks" array; flat (Cursor-style) entry
    # has the command directly.
    if "hooks" in entry:
        return any(FINGERPRINT in h.get("command", "") for h in entry.get("hooks", []))
    return FINGERPRINT in entry.get("command", "")


def process(source: str, path: Path, specs: list, remove: bool, flat: bool = False) -> str:
    if path.exists():
        data = json.loads(path.read_text())
    elif remove:
        return "absent"
    else:
        data = {}
    hooks = data.setdefault("hooks", {})
    changed = False

    if remove:
        for event in list(hooks):
            kept = [e for e in hooks[event] if not is_atoll(e)]
            if len(kept) != len(hooks[event]):
                changed = True
                if kept:
                    hooks[event] = kept
                else:
                    del hooks[event]
        if not hooks:
            data.pop("hooks", None)
        if source == "claude" and restore_statusline(data):
            changed = True
    else:
        # Prune Atoll-owned entries no longer in the desired spec, so shrinking an
        # agent's event set (e.g. dropping an unsupported event) actually takes
        # effect. Only Atoll's own entries are touched; other tools are preserved.
        desired = {(event, matcher) for event, matcher, _t, _h in specs}
        for event in list(hooks):
            kept = [e for e in hooks[event]
                    if not is_atoll(e) or (event, e.get("matcher")) in desired]
            if len(kept) != len(hooks[event]):
                changed = True
                if kept:
                    hooks[event] = kept
                else:
                    del hooks[event]
        for event, matcher, timeout, hold in specs:
            entries = hooks.setdefault(event, [])
            if any(is_atoll(e) and e.get("matcher") == matcher for e in entries):
                continue
            if flat:
                # Cursor flat format: {command, timeout} directly.
                entry = {"command": cmd(source, hold), "timeout": timeout}
            else:
                entry = {"hooks": [{"type": "command", "command": cmd(source, hold), "timeout": timeout}]}
                if matcher is not None:
                    entry["matcher"] = matcher
            entries.append(entry)
            changed = True
        if source == "claude" and wrap_statusline(data):
            changed = True

    if not changed:
        return "unchanged"

    if path.exists():
        backup = path.with_suffix(f".json.atoll-backup-{time.strftime('%Y%m%d-%H%M%S')}")
        shutil.copy2(path, backup)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.atoll-tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(path)
    return "removed" if remove else "installed"


def strip_kimi_blocks(contents: str) -> str:
    """Remove only marker-owned [[hooks]] blocks; preserve all user TOML."""
    lines = contents.splitlines(keepends=True)
    kept = []
    i = 0
    while i < len(lines):
        if lines[i].strip() != KIMI_MARKER:
            kept.append(lines[i])
            i += 1
            continue
        i += 1
        while i < len(lines) and not lines[i].strip():
            i += 1
        if i >= len(lines) or lines[i].strip() != "[[hooks]]":
            kept.append(KIMI_MARKER + "\n")
            continue
        i += 1
        while i < len(lines) and lines[i].strip() != KIMI_MARKER \
                and not lines[i].lstrip().startswith("[["):
            i += 1
    return "".join(kept).rstrip() + ("\n" if kept else "")


def strip_empty_kimi_hooks(contents: str) -> str:
    """Remove Kimi's top-level `hooks = []`, which conflicts with [[hooks]]."""
    kept = []
    entered_table = False
    for line in contents.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith("["):
            entered_table = True
        if not entered_table and stripped.replace(" ", "") == "hooks=[]":
            continue
        kept.append(line)
    return "".join(kept)


def process_kimi(remove: bool) -> str:
    existing = KIMI_PATH.read_text() if KIMI_PATH.exists() else ""
    cleaned = strip_kimi_blocks(existing)
    if remove:
        output = cleaned
    else:
        cleaned = strip_empty_kimi_hooks(cleaned)
        blocks = []
        for event, matcher in KIMI_EVENTS:
            values = [KIMI_MARKER, "[[hooks]]", f'name = {json.dumps(event)}']
            if matcher:
                values.append(f'matcher = {json.dumps(matcher)}')
            values.extend([
                f'command = {json.dumps(cmd("kimi"))}',
                "timeout = 10",
            ])
            blocks.append("\n".join(values))
        output = cleaned.rstrip() + ("\n\n" if cleaned.strip() else "") + "\n\n".join(blocks) + "\n"
    if output == existing:
        return "unchanged"
    if KIMI_PATH.exists():
        backup = KIMI_PATH.with_suffix(f".toml.atoll-backup-{time.strftime('%Y%m%d-%H%M%S')}")
        shutil.copy2(KIMI_PATH, backup)
    KIMI_PATH.parent.mkdir(parents=True, exist_ok=True)
    if remove and not output.strip():
        KIMI_PATH.unlink(missing_ok=True)
    else:
        tmp = KIMI_PATH.with_suffix(".toml.atoll-tmp")
        tmp.write_text(output)
        tmp.replace(KIMI_PATH)
    return "removed" if remove else "installed"


def process_opencode(remove: bool) -> str:
    config_path = opencode_config_path()
    if config_path.exists():
        data = json.loads(config_path.read_text())
    else:
        data = {}
    reference = f"file://{OPENCODE_PLUGIN}"
    existing_plugins = data.get("plugin", [])
    plugins = [p for p in existing_plugins if p != reference]

    if remove:
        desired_plugins = plugins
        changed = desired_plugins != existing_plugins
        if desired_plugins:
            data["plugin"] = desired_plugins
        else:
            data.pop("plugin", None)
        if OPENCODE_PLUGIN.exists():
            OPENCODE_PLUGIN.unlink()
            changed = True
    else:
        if not OPENCODE_ASSET.exists():
            raise FileNotFoundError(f"missing OpenCode plugin asset: {OPENCODE_ASSET}")
        desired_plugins = plugins + [reference]
        changed = desired_plugins != existing_plugins
        data["plugin"] = desired_plugins
        asset = OPENCODE_ASSET.read_bytes()
        if not OPENCODE_PLUGIN.exists() or OPENCODE_PLUGIN.read_bytes() != asset:
            OPENCODE_PLUGIN.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(OPENCODE_ASSET, OPENCODE_PLUGIN)
            changed = True

    if not changed:
        return "unchanged"
    if config_path.exists():
        backup = config_path.with_suffix(f".json.atoll-backup-{time.strftime('%Y%m%d-%H%M%S')}")
        shutil.copy2(config_path, backup)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = config_path.with_suffix(config_path.suffix + ".atoll-tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(config_path)
    return "removed" if remove else "installed"


STATUSLINE = str(Path.home() / ".atoll" / "bin" / "atoll-statusline.sh")
WRAPPED_FILE = Path.home() / ".atoll" / "cache" / "wrapped-statusline"


def wrap_statusline(data: dict) -> bool:
    """Point statusLine at Atoll, preserving any existing command by chaining.
    The wrapped command is saved so the bridge can call through to it."""
    current = data.get("statusLine")
    our_cmd = f"/bin/sh '{STATUSLINE}'"
    if isinstance(current, dict) and FINGERPRINT in current.get("command", ""):
        return False  # already ours
    WRAPPED_FILE.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(current, dict) and current.get("command"):
        WRAPPED_FILE.write_text(current["command"])
    else:
        WRAPPED_FILE.write_text("")  # nothing to chain to
    data["statusLine"] = {"type": "command", "command": our_cmd}
    return True


def restore_statusline(data: dict) -> bool:
    """Undo wrap_statusline: put the original command back (or drop it)."""
    current = data.get("statusLine")
    if not (isinstance(current, dict) and FINGERPRINT in current.get("command", "")):
        return False
    original = WRAPPED_FILE.read_text().strip() if WRAPPED_FILE.exists() else ""
    if original:
        data["statusLine"] = {"type": "command", "command": original}
    else:
        data.pop("statusLine", None)
    WRAPPED_FILE.unlink(missing_ok=True)
    return True


def json_integration_diagnostic(source: str, cfg: dict, bridge_present: bool,
                                enabled: bool) -> dict:
    path = cfg["path"]
    installed = False
    missing = len(cfg["specs"])
    error = ""
    try:
        if path.exists():
            data = json.loads(path.read_text())
            hooks = data.get("hooks", {})
            installed = any(
                is_atoll(entry)
                for entries in hooks.values() if isinstance(entries, list)
                for entry in entries if isinstance(entry, dict)
            )
            missing = 0
            for event, matcher, _timeout, _hold in cfg["specs"]:
                entries = hooks.get(event, [])
                found = any(
                    isinstance(entry, dict) and is_atoll(entry)
                    and (cfg.get("flat", False) or entry.get("matcher") == matcher)
                    for entry in entries if isinstance(entries, list)
                )
                if not found:
                    missing += 1
    except (OSError, ValueError, TypeError) as exc:
        error = f"config-invalid: {exc}"
    if not error and (installed or enabled) and missing:
        error = f"hooks-missing: {missing}"
    if not error and installed and not bridge_present:
        error = "bridge-missing"
    return {
        "installed": installed,
        "enabled": enabled,
        "healthy": installed and missing == 0 and bridge_present and not error,
        "cliPresent": path.parent.exists(),
        "bridgePresent": bridge_present,
        "missingHooks": missing,
        "configPath": str(path),
        "error": error,
    }


def status() -> None:
    """Print diagnostic JSON for Integration Center 2.0.

    `installed` means at least one Atoll-owned entry exists. `healthy` is
    deliberately stricter: every required entry and the local bridge must be
    present. Parse failures are reported instead of being flattened to disabled.
    """
    try:
        desired = set(json.loads(ENABLED_FILE.read_text())) if ENABLED_FILE.exists() else set()
    except Exception:
        desired = set()

    out = {}
    for source, cfg in CONFIGS.items():
        enabled = source in desired
        if not ENABLED_FILE.exists():
            try:
                enabled = integration_installed(source)
            except Exception:
                enabled = False
        out[source] = json_integration_diagnostic(
            source, cfg, BRIDGE_PATH.is_file(), enabled
        )
    kimi_text = KIMI_PATH.read_text() if KIMI_PATH.exists() else ""
    kimi_installed = KIMI_MARKER in kimi_text
    out["kimi"] = {
        "installed": kimi_installed,
        "enabled": "kimi" in desired or (not ENABLED_FILE.exists() and kimi_installed),
        "healthy": kimi_installed and BRIDGE_PATH.is_file(),
        "cliPresent": KIMI_PATH.parent.exists(),
        "bridgePresent": BRIDGE_PATH.is_file(),
        "missingHooks": 0 if kimi_installed else len(KIMI_EVENTS),
        "configPath": str(KIMI_PATH),
        "error": "bridge-missing" if kimi_installed and not BRIDGE_PATH.is_file() else "",
    }
    open_config = opencode_config_path()
    open_error = ""
    try:
        open_plugins = json.loads(open_config.read_text()).get("plugin", []) if open_config.exists() else []
    except (OSError, ValueError, TypeError) as exc:
        open_plugins = []
        open_error = f"config-invalid: {exc}"
    open_installed = OPENCODE_PLUGIN.exists() and f"file://{OPENCODE_PLUGIN}" in open_plugins
    if not open_error and open_installed and not BRIDGE_PATH.is_file():
        open_error = "bridge-missing"
    out["opencode"] = {
        "installed": open_installed,
        "enabled": "opencode" in desired or (not ENABLED_FILE.exists() and open_installed),
        "healthy": open_installed and BRIDGE_PATH.is_file() and not open_error,
        "cliPresent": OPENCODE_DIR.exists(),
        "bridgePresent": BRIDGE_PATH.is_file(),
        "missingHooks": 0 if open_installed else 1,
        "configPath": str(open_config),
        "error": open_error,
    }
    print(json.dumps(out))


def jq_present() -> bool:
    """The bridge shells out to jq; report whether it's resolvable."""
    import shutil
    return shutil.which("jq") is not None or Path("/usr/bin/jq").exists()


def statusline_status() -> dict:
    """Report the statusLine bridge connection without changing anything."""
    path = CONFIGS["claude"]["path"]
    connected = False
    error = ""
    try:
        if path.exists():
            data = json.loads(path.read_text())
            current = data.get("statusLine")
            connected = isinstance(current, dict) and FINGERPRINT in current.get("command", "")
    except (OSError, ValueError, TypeError) as exc:
        error = f"config-invalid: {exc}"
    return {
        "connected": connected,
        "jqPresent": jq_present(),
        "bridgePresent": Path(STATUSLINE).exists(),
        "original": WRAPPED_FILE.read_text().strip() if WRAPPED_FILE.exists() else "",
        "error": error,
    }


def statusline_action(action: str) -> None:
    """connect / disconnect / status for the usage statusLine bridge. Connect and
    disconnect are idempotent and only touch Atoll-managed content; the user's
    original statusLine command is preserved on connect and restored on disconnect."""
    path = CONFIGS["claude"]["path"]
    if action == "status":
        print(json.dumps(statusline_status()))
        return
    try:
        data = json.loads(path.read_text()) if path.exists() else {}
    except (OSError, ValueError) as exc:
        print(json.dumps({"ok": False, "error": f"config-invalid: {exc}"}))
        return
    if action == "connect":
        if not jq_present():
            print(json.dumps({"ok": False,
                              "error": "jq-missing: 请先安装 jq（brew install jq）后再连接。"}))
            return
        changed = wrap_statusline(data)
    elif action == "disconnect":
        changed = restore_statusline(data)
    else:
        print(json.dumps({"ok": False, "error": f"unknown-action: {action}"}))
        return
    if changed:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2))
    print(json.dumps({"ok": True, "changed": changed, **statusline_status()}))


# ── Extra config directories (multiple Claude/Codex accounts or forks) ──────
EXTRA_DIRS_FILE = Path.home() / ".atoll" / "config" / "extra-config-dirs.json"
# The config filename Atoll manages inside an extra directory, per source.
EXTRA_DIR_FILENAME = {"claude": "settings.json", "codex": "hooks.json"}


def load_extra_dirs() -> dict:
    try:
        data = json.loads(EXTRA_DIRS_FILE.read_text()) if EXTRA_DIRS_FILE.exists() else {}
    except (OSError, ValueError):
        return {}
    return {k: list(dict.fromkeys(v)) for k, v in data.items() if k in EXTRA_DIR_FILENAME}


def save_extra_dirs(data: dict) -> None:
    EXTRA_DIRS_FILE.parent.mkdir(parents=True, exist_ok=True)
    EXTRA_DIRS_FILE.write_text(json.dumps(data, indent=2))


def extra_config_path(source: str, directory: str) -> Path:
    return Path(directory).expanduser() / EXTRA_DIR_FILENAME[source]


def add_extra_dir(source: str, directory: str) -> dict:
    """Register an extra config directory. The directory must exist; the config
    file inside it is safe-created empty if absent. Duplicates are rejected."""
    if source not in EXTRA_DIR_FILENAME:
        return {"ok": False, "error": f"unsupported-source: {source}"}
    d = Path(directory).expanduser()
    if not d.exists():
        return {"ok": False, "error": "path-not-exist"}
    if not d.is_dir():
        return {"ok": False, "error": "path-not-a-directory"}
    dirs = load_extra_dirs()
    existing = dirs.get(source, [])
    if str(d) in existing:
        return {"ok": False, "error": "duplicate"}
    cfg = extra_config_path(source, str(d))
    try:
        if not cfg.exists():
            cfg.write_text("{}")
        else:
            json.loads(cfg.read_text())  # validate readable JSON
    except PermissionError:
        return {"ok": False, "error": "permission-denied"}
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": f"config-invalid: {exc}"}
    dirs.setdefault(source, []).append(str(d))
    save_extra_dirs(dirs)
    return {"ok": True, "path": str(d)}


def remove_extra_dir(source: str, directory: str, remove_hooks: bool) -> dict:
    d = str(Path(directory).expanduser())
    dirs = load_extra_dirs()
    if d not in dirs.get(source, []):
        return {"ok": False, "error": "not-registered"}
    if remove_hooks:
        cfg = extra_config_path(source, d)
        if cfg.exists():
            process(source, cfg, CONFIGS[source]["specs"], True,
                    CONFIGS[source].get("flat", False))
    dirs[source] = [x for x in dirs[source] if x != d]
    if not dirs[source]:
        dirs.pop(source, None)
    save_extra_dirs(dirs)
    return {"ok": True, "removedHooks": remove_hooks}


def extra_dirs_status() -> list:
    """Per-directory diagnostic entries for extra config directories."""
    out = []
    for source, directories in load_extra_dirs().items():
        for d in directories:
            cfg = extra_config_path(source, d)
            diag = json_integration_diagnostic(
                source, {"path": cfg, "specs": CONFIGS[source]["specs"],
                         "flat": CONFIGS[source].get("flat", False)},
                BRIDGE_PATH.is_file(), True)
            diag["source"] = source
            diag["directory"] = d
            out.append(diag)
    return out


def process_extra_dirs(source_filter, remove: bool) -> None:
    for source, directories in load_extra_dirs().items():
        if source_filter and source != source_filter:
            continue
        for d in directories:
            cfg = extra_config_path(source, d)
            result = process(source, cfg, CONFIGS[source]["specs"], remove,
                             CONFIGS[source].get("flat", False))
            print(f"{source}@{d}: {result}")


def main() -> None:
    if "--status" in sys.argv:
        status()
        return
    if "--extra-status" in sys.argv:
        print(json.dumps(extra_dirs_status()))
        return
    if "--add-dir" in sys.argv:
        i = sys.argv.index("--add-dir")
        print(json.dumps(add_extra_dir(sys.argv[i + 1], sys.argv[i + 2])))
        return
    if "--remove-dir" in sys.argv:
        i = sys.argv.index("--remove-dir")
        print(json.dumps(remove_extra_dir(sys.argv[i + 1], sys.argv[i + 2],
                                          "--remove-hooks" in sys.argv)))
        return
    if "--statusline" in sys.argv:
        i = sys.argv.index("--statusline")
        action = sys.argv[i + 1] if i + 1 < len(sys.argv) else "status"
        statusline_action(action)
        return
    remove = "--remove" in sys.argv
    restore = "--restore" in sys.argv
    # --only <source> restricts to a single CLI (used by the Settings toggles).
    only = None
    if "--only" in sys.argv:
        i = sys.argv.index("--only")
        if i + 1 < len(sys.argv):
            only = sys.argv[i + 1]
    restore_sources = enabled_integrations() if restore else None
    for source, cfg in CONFIGS.items():
        if (only and source != only) or (restore_sources is not None and source not in restore_sources):
            continue
        result = process(source, cfg["path"], cfg["specs"], remove, cfg.get("flat", False))
        print(f"{source}: {result}")
        if not restore:
            record_enabled(source, not remove)
    if (not only or only == "kimi") and (restore_sources is None or "kimi" in restore_sources):
        print(f"kimi: {process_kimi(remove)}")
        if not restore:
            record_enabled("kimi", not remove)
    if (not only or only == "opencode") and (restore_sources is None or "opencode" in restore_sources):
        print(f"opencode: {process_opencode(remove)}")
        if not restore:
            record_enabled("opencode", not remove)
    # Extra config directories only ever process on explicit enable — restore
    # (HookWatcher) only touches the standard, explicitly-enabled locations.
    if not restore:
        process_extra_dirs(only, remove)


if __name__ == "__main__":
    main()
