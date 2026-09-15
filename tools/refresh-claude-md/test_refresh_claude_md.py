from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).parent
SCRIPT = THIS_DIR / "refresh_claude_md.py"


class CliCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.target = self.root / "TARGET.md"
        self.manifest = self.root / "manifest.toml"

    def run_cli(self, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["HOME"] = str(self.root)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.target), str(self.manifest)],
            capture_output=True, text=True, env=env, timeout=30,
        )

    def write_target(self, body: str) -> None:
        self.target.write_text(body, encoding="utf-8")
        os.chmod(self.target, 0o644)

    def write_manifest(self, body: str) -> None:
        self.manifest.write_text(body, encoding="utf-8")
        os.chmod(self.manifest, 0o644)

    def test_basic_replacement(self) -> None:
        self.write_target("HEADER\n<!-- AUTO-START -->\nold\n<!-- AUTO-END -->\nFOOTER\n")
        self.write_manifest(
            'title = "Estado (auto)"\n'
            '[[field]]\nlabel = "Echo"\ncommand = "echo hello"\ndefault = "?"\n'
            '[[field]]\nlabel = "Two"\ncommand = "printf %s 42"\ndefault = "?"\n'
        )
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.target.read_text(encoding="utf-8")
        self.assertIn("- Echo: hello", out)
        self.assertIn("- Two: 42", out)
        self.assertIn("HEADER", out)
        self.assertIn("FOOTER", out)
        self.assertNotIn("old", out)

    def test_missing_markers_exits_1_and_no_change(self) -> None:
        original = "no markers here\n"
        self.write_target(original)
        self.write_manifest('[[field]]\nlabel = "X"\ncommand = "echo y"\ndefault = "?"\n')
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.target.read_text(encoding="utf-8"), original)

    def test_failing_command_uses_default(self) -> None:
        self.write_target("<!-- AUTO-START -->\nx\n<!-- AUTO-END -->\n")
        self.write_manifest(
            '[[field]]\nlabel = "Bad"\ncommand = "false"\ndefault = "MISSING"\n'
        )
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.target.read_text(encoding="utf-8")
        self.assertIn("- Bad: MISSING", out)

    def test_invalid_toml_exits_2_and_no_change(self) -> None:
        original = "<!-- AUTO-START -->\nx\n<!-- AUTO-END -->\n"
        self.write_target(original)
        self.write_manifest("this is = not = valid = toml\n[[\n")
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.target.read_text(encoding="utf-8"), original)

    def test_idempotent_two_runs(self) -> None:
        self.write_target("<!-- AUTO-START -->\n<!-- AUTO-END -->\n")
        self.write_manifest('[[field]]\nlabel = "S"\ncommand = "echo same"\ndefault = "?"\n')
        self.assertEqual(self.run_cli().returncode, 0)
        first = self.target.read_text(encoding="utf-8")
        self.assertEqual(self.run_cli().returncode, 0)
        second = self.target.read_text(encoding="utf-8")
        self.assertEqual(first, second)

    def test_multiline_output_collapsed(self) -> None:
        self.write_target("<!-- AUTO-START -->\n<!-- AUTO-END -->\n")
        self.write_manifest(
            '[[field]]\nlabel = "M"\n'
            "command = \"bash -c 'echo a; echo b'\"\ndefault = \"?\"\n"
        )
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.target.read_text(encoding="utf-8")
        self.assertIn("- M: a b", out)

    def test_empty_manifest_renders_placeholder(self) -> None:
        self.write_target("<!-- AUTO-START -->\nx\n<!-- AUTO-END -->\n")
        self.write_manifest('title = "Vacío"\n')
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.target.read_text(encoding="utf-8")
        self.assertIn("## Vacío", out)
        self.assertIn("- (sin campos)", out)

    def test_inline_mention_not_expanded(self) -> None:
        self.write_target(
            "DOC\n"
            "mencion `<!-- AUTO-START --> ... <!-- AUTO-END -->` inline.\n"
            "\n"
            "<!-- AUTO-START -->\n"
            "old\n"
            "<!-- AUTO-END -->\n"
        )
        self.write_manifest('[[field]]\nlabel = "E"\ncommand = "echo nuevo"\ndefault = "?"\n')
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.target.read_text(encoding="utf-8")
        self.assertIn("mencion `<!-- AUTO-START --> ... <!-- AUTO-END -->` inline.", out)
        self.assertIn("- E: nuevo", out)
        self.assertNotIn("old", out)
        self.assertEqual(out.count("- E: nuevo"), 1)

    def test_symlink_target_rejected(self) -> None:
        real = self.root / "REAL.md"
        original = "<!-- AUTO-START -->\nold\n<!-- AUTO-END -->\n"
        real.write_text(original, encoding="utf-8")
        self.target.symlink_to(real)
        self.write_manifest('[[field]]\nlabel = "E"\ncommand = "echo hi"\ndefault = "?"\n')
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(real.read_text(encoding="utf-8"), original)

    def test_world_writable_target_rejected(self) -> None:
        self.write_target("<!-- AUTO-START -->\nold\n<!-- AUTO-END -->\n")
        os.chmod(self.target, 0o666)
        self.write_manifest('[[field]]\nlabel = "E"\ncommand = "echo hi"\ndefault = "?"\n')
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)

    def test_group_writable_manifest_rejected(self) -> None:
        self.write_target("<!-- AUTO-START -->\nold\n<!-- AUTO-END -->\n")
        self.write_manifest('[[field]]\nlabel = "E"\ncommand = "echo hi"\ndefault = "?"\n')
        os.chmod(self.manifest, 0o664)
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)

    def test_missing_markers_does_not_run_commands(self) -> None:
        sentinel = self.root / "sentinel"
        self.write_target("no markers here\n")
        self.write_manifest(
            f'[[field]]\nlabel = "E"\ncommand = "touch {sentinel}"\ndefault = "?"\n'
        )
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(sentinel.exists())

    def test_budget_exhausted_leaves_later_fields_at_default(self) -> None:
        sentinel = self.root / "sentinel"
        self.write_target("<!-- AUTO-START -->\nold\n<!-- AUTO-END -->\n")
        self.write_manifest(
            '[[field]]\nlabel = "A"\ncommand = "sleep 3"\ndefault = "DEF-A"\n'
            f'[[field]]\nlabel = "B"\ncommand = "touch {sentinel}"\ndefault = "DEF-B"\n'
        )
        started = time.monotonic()
        result = self.run_cli(extra_env={"REFRESH_CLAUDE_MD_BUDGET": "1"})
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 3)
        out = self.target.read_text(encoding="utf-8")
        self.assertIn("- A: DEF-A", out)
        self.assertIn("- B: DEF-B", out)
        self.assertFalse(sentinel.exists())

    def test_per_field_timeout_capped_by_remaining_budget(self) -> None:
        self.write_target("<!-- AUTO-START -->\nold\n<!-- AUTO-END -->\n")
        self.write_manifest(
            '[[field]]\nlabel = "A"\ncommand = "sleep 5"\ndefault = "DEF-A"\n'
        )
        started = time.monotonic()
        result = self.run_cli(extra_env={"REFRESH_CLAUDE_MD_BUDGET": "1"})
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 3)
        out = self.target.read_text(encoding="utf-8")
        self.assertIn("- A: DEF-A", out)

    def test_non_finite_budget_env_falls_back_to_default(self) -> None:
        for raw in ("nan", "inf", "-inf"):
            with self.subTest(raw=raw):
                self.write_target("<!-- AUTO-START -->\nold\n<!-- AUTO-END -->\n")
                self.write_manifest('[[field]]\nlabel = "E"\ncommand = "echo ok"\ndefault = "?"\n')
                result = self.run_cli(extra_env={"REFRESH_CLAUDE_MD_BUDGET": raw})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("- E: ok", self.target.read_text(encoding="utf-8"))

    def test_resolve_budget_rejects_non_finite(self) -> None:
        import importlib.util
        spec = importlib.util.spec_from_file_location("refresh_claude_md", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        for raw in ("nan", "inf", "-inf", "0", "-3", "x"):
            os.environ["REFRESH_CLAUDE_MD_BUDGET"] = raw
            try:
                self.assertEqual(mod.resolve_budget(), mod.DEFAULT_BUDGET, raw)
            finally:
                del os.environ["REFRESH_CLAUDE_MD_BUDGET"]
        os.environ["REFRESH_CLAUDE_MD_BUDGET"] = "2.5"
        try:
            self.assertEqual(mod.resolve_budget(), 2.5)
        finally:
            del os.environ["REFRESH_CLAUDE_MD_BUDGET"]

    def test_invalid_budget_env_falls_back_to_default(self) -> None:
        self.write_target("<!-- AUTO-START -->\nold\n<!-- AUTO-END -->\n")
        self.write_manifest('[[field]]\nlabel = "E"\ncommand = "echo ok"\ndefault = "?"\n')
        result = self.run_cli(extra_env={"REFRESH_CLAUDE_MD_BUDGET": "not-a-number"})
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.target.read_text(encoding="utf-8")
        self.assertIn("- E: ok", out)

    def test_field_without_command_uses_default_and_counts_failed(self) -> None:
        self.write_target("<!-- AUTO-START -->\nold\n<!-- AUTO-END -->\n")
        self.write_manifest(
            '[[field]]\nlabel = "NoCmd"\ndefault = "DEF-NOCMD"\n'
            '[[field]]\nlabel = "Ok"\ncommand = "echo ok"\ndefault = "?"\n'
        )
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.target.read_text(encoding="utf-8")
        self.assertIn("- NoCmd: DEF-NOCMD", out)
        self.assertIn("- Ok: ok", out)
        log = self.root / ".claude" / "logs" / "refresh-claude-md.log"
        last = log.read_text(encoding="utf-8").strip().splitlines()[-1]
        self.assertIn('"fields_ok": 1', last)
        self.assertIn('"fields_failed": 1', last)

    def test_field_without_label_dropped_and_counts_failed(self) -> None:
        self.write_target("<!-- AUTO-START -->\nold\n<!-- AUTO-END -->\n")
        self.write_manifest(
            '[[field]]\ncommand = "echo orphan"\ndefault = "?"\n'
            '[[field]]\nlabel = "Ok"\ncommand = "echo ok"\ndefault = "?"\n'
        )
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.target.read_text(encoding="utf-8")
        self.assertNotIn("orphan", out)
        self.assertIn("- Ok: ok", out)
        log = self.root / ".claude" / "logs" / "refresh-claude-md.log"
        last = log.read_text(encoding="utf-8").strip().splitlines()[-1]
        self.assertIn('"fields_ok": 1', last)
        self.assertIn('"fields_failed": 1', last)

    def test_resolve_budget_clamped_to_max(self) -> None:
        import importlib.util
        spec = importlib.util.spec_from_file_location("refresh_claude_md", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertEqual(mod.MAX_BUDGET, mod.TIMEOUT - 1.0)
        os.environ["REFRESH_CLAUDE_MD_BUDGET"] = "999"
        try:
            self.assertEqual(mod.resolve_budget(), mod.MAX_BUDGET)
        finally:
            del os.environ["REFRESH_CLAUDE_MD_BUDGET"]
        os.environ["REFRESH_CLAUDE_MD_BUDGET"] = "2.5"
        try:
            self.assertEqual(mod.resolve_budget(), 2.5)
        finally:
            del os.environ["REFRESH_CLAUDE_MD_BUDGET"]

    def test_audit_log_written(self) -> None:
        self.write_target("<!-- AUTO-START -->\nx\n<!-- AUTO-END -->\n")
        self.write_manifest('[[field]]\nlabel = "E"\ncommand = "echo ok"\ndefault = "?"\n')
        self.assertEqual(self.run_cli().returncode, 0)
        log = self.root / ".claude" / "logs" / "refresh-claude-md.log"
        self.assertTrue(log.is_file())
        content = log.read_text(encoding="utf-8").strip().splitlines()
        self.assertTrue(content)
        last = content[-1]
        self.assertIn('"event": "refresh_md"', last)
        self.assertIn('"fields_ok": 1', last)


if __name__ == "__main__":
    unittest.main()
