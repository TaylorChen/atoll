import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "install_hooks", Path(__file__).with_name("install-hooks.py")
)
hooks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hooks)


class InstallHooksTests(unittest.TestCase):
    def test_enabled_manifest_changes_only_the_requested_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = hooks.ENABLED_FILE
            try:
                hooks.ENABLED_FILE = Path(tmp) / "enabled.json"
                hooks.ENABLED_FILE.write_text('["claude", "codex"]\n')

                hooks.record_enabled("qwen", True)
                hooks.record_enabled("codex", False)

                self.assertEqual(json.loads(hooks.ENABLED_FILE.read_text()), ["claude", "qwen"])
            finally:
                hooks.ENABLED_FILE = old

    def test_json_hook_install_preserves_existing_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "settings.json"
            existing = {"theme": "dark", "hooks": {"Stop": [{"hooks": [{"command": "other"}]}]}}
            path.write_text(json.dumps(existing))

            result = hooks.process("qwen", path, [("Stop", None, 10, False)], False)
            data = json.loads(path.read_text())

            self.assertEqual(result, "installed")
            self.assertEqual(data["theme"], "dark")
            self.assertEqual(len(data["hooks"]["Stop"]), 2)

    def test_kimi_cleanup_removes_only_atoll_blocks(self):
        text = """model = \"kimi\"

# atoll: managed hook — do not edit
[[hooks]]
name = \"Stop\"
command = \"atoll\"

[[hooks]]
name = \"UserHook\"
command = \"mine\"
"""
        cleaned = hooks.strip_kimi_blocks(text)

        self.assertNotIn("command = \"atoll\"", cleaned)
        self.assertIn("command = \"mine\"", cleaned)
        self.assertIn("model = \"kimi\"", cleaned)

    def test_kimi_empty_placeholder_is_removed_before_array_tables(self):
        text = "hooks = []\nmodel = \"kimi\"\n"
        self.assertEqual(hooks.strip_empty_kimi_hooks(text), 'model = "kimi"\n')

    def test_opencode_install_and_remove_preserve_other_plugins(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = (hooks.OPENCODE_DIR, hooks.OPENCODE_PLUGIN, hooks.OPENCODE_ASSET)
            try:
                hooks.OPENCODE_DIR = root / "opencode"
                hooks.OPENCODE_PLUGIN = hooks.OPENCODE_DIR / "plugins" / "atoll.js"
                hooks.OPENCODE_ASSET = root / "asset.js"
                hooks.OPENCODE_ASSET.write_text("export default () => ({})\n")
                config = hooks.OPENCODE_DIR / "config.json"
                config.parent.mkdir(parents=True)
                config.write_text(json.dumps({"plugin": ["other-plugin"], "theme": "dark"}))

                self.assertEqual(hooks.process_opencode(False), "installed")
                installed = json.loads(config.read_text())
                self.assertIn("other-plugin", installed["plugin"])
                self.assertEqual(installed["theme"], "dark")
                self.assertTrue(hooks.OPENCODE_PLUGIN.exists())
                self.assertEqual(hooks.process_opencode(False), "unchanged")

                self.assertEqual(hooks.process_opencode(True), "removed")
                removed = json.loads(config.read_text())
                self.assertEqual(removed["plugin"], ["other-plugin"])
                self.assertFalse(hooks.OPENCODE_PLUGIN.exists())
            finally:
                hooks.OPENCODE_DIR, hooks.OPENCODE_PLUGIN, hooks.OPENCODE_ASSET = old

    def test_diagnostic_distinguishes_partial_and_healthy_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "settings.json"
            cfg = {
                "path": path,
                "specs": [
                    ("SessionStart", None, 10, False),
                    ("PermissionRequest", "*", 3600, True),
                ],
            }
            path.write_text(json.dumps({
                "hooks": {
                    "SessionStart": [{"hooks": [{"command": hooks.cmd("qwen")}]}],
                }
            }))

            partial = hooks.json_integration_diagnostic("qwen", cfg, True, True)
            self.assertTrue(partial["installed"])
            self.assertFalse(partial["healthy"])
            self.assertEqual(partial["missingHooks"], 1)
            self.assertEqual(partial["error"], "hooks-missing: 1")

            hooks.process("qwen", path, cfg["specs"], False)
            healthy = hooks.json_integration_diagnostic("qwen", cfg, True, True)
            self.assertTrue(healthy["healthy"])
            self.assertEqual(healthy["missingHooks"], 0)
            self.assertEqual(healthy["error"], "")

    def test_diagnostic_surfaces_invalid_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "settings.json"
            path.write_text("{not-json")
            diagnostic = hooks.json_integration_diagnostic(
                "codex", {"path": path, "specs": []}, True, True
            )

            self.assertFalse(diagnostic["healthy"])
            self.assertTrue(diagnostic["error"].startswith("config-invalid:"))


class StatusLineBridgeTests(unittest.TestCase):
    def _with_wrapped(self, tmp):
        self._old_wrapped = hooks.WRAPPED_FILE
        hooks.WRAPPED_FILE = Path(tmp) / "wrapped-statusline"

    def tearDown(self):
        if hasattr(self, "_old_wrapped"):
            hooks.WRAPPED_FILE = self._old_wrapped

    def test_connect_preserves_and_chains_existing_statusline(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._with_wrapped(tmp)
            data = {"statusLine": {"type": "command", "command": "my-own-line"}}
            self.assertTrue(hooks.wrap_statusline(data))
            self.assertIn(hooks.FINGERPRINT, data["statusLine"]["command"])
            self.assertEqual(hooks.WRAPPED_FILE.read_text(), "my-own-line")

    def test_connect_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._with_wrapped(tmp)
            data = {}
            self.assertTrue(hooks.wrap_statusline(data))
            self.assertFalse(hooks.wrap_statusline(data), "connecting twice is a no-op")

    def test_disconnect_restores_original_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._with_wrapped(tmp)
            data = {"statusLine": {"type": "command", "command": "my-own-line"}}
            hooks.wrap_statusline(data)
            self.assertTrue(hooks.restore_statusline(data))
            self.assertEqual(data["statusLine"]["command"], "my-own-line")
            self.assertFalse(hooks.WRAPPED_FILE.exists(), "wrapped cache is cleaned up")

    def test_disconnect_drops_statusline_when_there_was_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._with_wrapped(tmp)
            data = {}
            hooks.wrap_statusline(data)             # no prior statusLine
            self.assertTrue(hooks.restore_statusline(data))
            self.assertNotIn("statusLine", data, "no ghost statusLine left behind")

    def test_disconnect_on_unmanaged_config_is_noop(self):
        data = {"statusLine": {"type": "command", "command": "someone-elses"}}
        self.assertFalse(hooks.restore_statusline(data))
        self.assertEqual(data["statusLine"]["command"], "someone-elses")


class ExtraConfigDirTests(unittest.TestCase):
    def setUp(self):
        self._old = hooks.EXTRA_DIRS_FILE
        self._tmp = tempfile.TemporaryDirectory()
        hooks.EXTRA_DIRS_FILE = Path(self._tmp.name) / "extra-config-dirs.json"

    def tearDown(self):
        hooks.EXTRA_DIRS_FILE = self._old
        self._tmp.cleanup()

    def test_add_creates_empty_config_and_registers(self):
        with tempfile.TemporaryDirectory() as d:
            result = hooks.add_extra_dir("claude", d)
            self.assertTrue(result["ok"])
            self.assertTrue((Path(d) / "settings.json").exists())
            self.assertEqual(hooks.load_extra_dirs()["claude"], [str(Path(d))])

    def test_add_rejects_missing_directory(self):
        result = hooks.add_extra_dir("claude", "/no/such/dir")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "path-not-exist")

    def test_add_rejects_duplicate(self):
        with tempfile.TemporaryDirectory() as d:
            hooks.add_extra_dir("claude", d)
            second = hooks.add_extra_dir("claude", d)
            self.assertFalse(second["ok"])
            self.assertEqual(second["error"], "duplicate")

    def test_add_reports_corrupt_config(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "settings.json").write_text("{not json")
            result = hooks.add_extra_dir("claude", d)
            self.assertFalse(result["ok"])
            self.assertTrue(result["error"].startswith("config-invalid:"))

    def test_two_dirs_install_in_parallel_and_status_is_per_dir(self):
        with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
            hooks.add_extra_dir("claude", d1)
            hooks.add_extra_dir("claude", d2)
            hooks.process_extra_dirs("claude", remove=False)
            statuses = hooks.extra_dirs_status()
            self.assertEqual(len(statuses), 2)
            for s in statuses:
                self.assertTrue(s["installed"], f"{s['directory']} should be configured")

    def test_remove_dir_can_strip_hooks_and_preserves_others(self):
        with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
            hooks.add_extra_dir("claude", d1)
            hooks.add_extra_dir("claude", d2)
            hooks.process_extra_dirs("claude", remove=False)
            hooks.remove_extra_dir("claude", d1, remove_hooks=True)
            # d1 unregistered and its hooks removed; d2 still registered + installed.
            self.assertEqual(hooks.load_extra_dirs().get("claude"), [str(Path(d2))])
            d1_data = json.loads((Path(d1) / "settings.json").read_text())
            self.assertFalse(any(
                hooks.is_atoll(e)
                for entries in d1_data.get("hooks", {}).values() if isinstance(entries, list)
                for e in entries if isinstance(e, dict)))
            statuses = {s["directory"]: s for s in hooks.extra_dirs_status()}
            self.assertTrue(statuses[str(Path(d2))]["installed"])


class PruneOnShrinkTests(unittest.TestCase):
    def test_install_prunes_atoll_events_no_longer_in_spec(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "settings.json"
            # Install the full set, then reinstall a shrunk set.
            full = [("SessionStart", None, 10, False), ("PermissionRequest", "*", 3600, True)]
            hooks.process("qoder", path, full, remove=False)
            self.assertIn("PermissionRequest", json.loads(path.read_text())["hooks"])

            shrunk = [("SessionStart", None, 10, False)]
            hooks.process("qoder", path, shrunk, remove=False)
            events = json.loads(path.read_text())["hooks"]
            self.assertIn("SessionStart", events)
            self.assertNotIn("PermissionRequest", events,
                             "dropping an event from the spec must prune its Atoll entry")

    def test_prune_preserves_other_tools_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "settings.json"
            existing = {"hooks": {"PermissionRequest": [{"hooks": [{"command": "other-tool"}]}]}}
            path.write_text(json.dumps(existing))
            hooks.process("qoder", path, [("SessionStart", None, 10, False)], remove=False)
            data = json.loads(path.read_text())["hooks"]
            self.assertEqual(data["PermissionRequest"][0]["hooks"][0]["command"], "other-tool")

    def test_prune_is_matcher_aware(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "settings.json"
            both = [("PreToolUse", "*", 10, False), ("PreToolUse", "AskUserQuestion", 3600, True)]
            hooks.process("claude", path, both, remove=False)
            # Drop the AskUserQuestion matcher; keep "*".
            hooks.process("claude", path, [("PreToolUse", "*", 10, False)], remove=False)
            entries = json.loads(path.read_text())["hooks"]["PreToolUse"]
            matchers = {e.get("matcher") for e in entries if hooks.is_atoll(e)}
            self.assertEqual(matchers, {"*"}, "the dropped matcher's entry is pruned")


class QoderMonitorOnlyTests(unittest.TestCase):
    def test_qoder_installs_only_the_events_it_recognizes(self):
        specs = hooks.CONFIGS["qoder"]["specs"]
        events = {name for name, _matcher, _timeout, _hold in specs}
        # QoderWork only keeps SessionStart/Stop/SessionEnd (it strips the rest on
        # launch) and executes none of them; install just those to avoid churn.
        self.assertEqual(events, {"SessionStart", "Stop", "SessionEnd"})
        self.assertNotIn("PermissionRequest", events)
        self.assertTrue(all(not hold for *_rest, hold in specs), "qoder events are monitor-only")

    def test_qoder_install_is_non_destructive_to_other_tools(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "settings.json"
            existing = {"hooks": {"PermissionRequest": [{"hooks": [{"command": "other-tool"}]}]}}
            path.write_text(json.dumps(existing))
            hooks.process("qoder", path, hooks.CONFIGS["qoder"]["specs"], remove=False)
            data = json.loads(path.read_text())
            # Another tool's PermissionRequest entry is preserved untouched.
            self.assertEqual(data["hooks"]["PermissionRequest"][0]["hooks"][0]["command"], "other-tool")
            # Atoll only added its own supported events.
            self.assertIn("SessionStart", data["hooks"])


if __name__ == "__main__":
    unittest.main()
