#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import math
import os
import shlex
import stat
import subprocess
import sys
import tempfile
import time
import tomllib
from datetime import datetime, timezone
from pathlib import Path

START = "<!-- AUTO-START -->"
END = "<!-- AUTO-END -->"
TIMEOUT = 10
DEFAULT_BUDGET = 8.0
MAX_BUDGET = TIMEOUT - 1.0
DEFAULT_TITLE = "Estado (auto)"
AUDIT_LOG = Path.home() / ".claude" / "logs" / "refresh-claude-md.log"
MAX_FIELD_LEN = 200


def audit(event: str, **kw) -> None:
    try:
        AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps(
            {"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "event": event, **kw},
            ensure_ascii=False,
        )
        with AUDIT_LOG.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def sanitize(text: str, limit: int = MAX_FIELD_LEN) -> str:
    text = " ".join(text.split())
    text = text.replace("<!--", "").replace("-->", "")
    if len(text) > limit:
        text = text[:limit] + "..."
    return text


def resolve_budget() -> float:
    raw = os.environ.get("REFRESH_CLAUDE_MD_BUDGET")
    if raw is None:
        return DEFAULT_BUDGET
    try:
        val = float(raw)
    except ValueError:
        return DEFAULT_BUDGET
    if not math.isfinite(val) or val <= 0:
        return DEFAULT_BUDGET
    return min(val, MAX_BUDGET)


def run_field(cmd: str, default: str, cwd: Path, timeout: float) -> tuple[str, bool]:
    try:
        argv = shlex.split(cmd)
        if not argv:
            return default, False
        proc = subprocess.run(
            argv,
            shell=False,
            cwd=str(cwd),
            timeout=timeout,
            capture_output=True,
            text=True,
            env=os.environ.copy(),
        )
        out = proc.stdout.strip()
        if proc.returncode != 0 or not out:
            return default, False
        return sanitize(out), True
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError, ValueError):
        return default, False


def render(title: str, rows: list[tuple[str, str]]) -> str:
    body = [START, f"## {title}"]
    if not rows:
        body.append("- (sin campos)")
    else:
        for label, value in rows:
            body.append(f"- {label}: {value}")
    body.append(END)
    return "\n".join(body)


def find_marker_line(text: str, marker: str, start: int = 0) -> int:
    pos = start
    while True:
        i = text.find(marker, pos)
        if i == -1:
            return -1
        end = i + len(marker)
        at_bol = i == 0 or text[i - 1] == "\n"
        at_eol = end == len(text) or text[end] == "\n"
        if at_bol and at_eol:
            return i
        pos = end


def locate_markers(text: str) -> tuple[int, int]:
    s = find_marker_line(text, START)
    if s == -1:
        raise ValueError("missing AUTO markers")
    if find_marker_line(text, START, s + len(START)) != -1:
        raise ValueError("multiple AUTO-START markers")
    e = find_marker_line(text, END, s + len(START))
    if e == -1:
        raise ValueError("missing AUTO markers")
    if find_marker_line(text, END, e + len(END)) != -1:
        raise ValueError("multiple AUTO-END markers")
    return s, e


def splice(target: Path, block: str) -> None:
    text = target.read_text(encoding="utf-8")
    s, e = locate_markers(text)
    new = f"{text[:s]}{block}{text[e + len(END):]}"
    if new == text:
        return
    orig_mode = stat.S_IMODE(target.stat().st_mode)
    tmp = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", delete=False,
        dir=str(target.parent), prefix=f".{target.name}.", suffix=".tmp",
    )
    try:
        tmp.write(new)
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp.close()
        os.chmod(tmp.name, orig_mode)
        os.replace(tmp.name, target)
        dirfd = os.open(str(target.parent), os.O_RDONLY)
        try:
            os.fsync(dirfd)
        finally:
            os.close(dirfd)
    except OSError:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
        raise


def load_manifest(path: Path) -> dict:
    with path.open("rb") as fh:
        return tomllib.load(fh)


def path_trusted(path: Path) -> bool:
    try:
        if path.is_symlink():
            return False
        st = path.lstat()
        if st.st_uid != os.getuid():
            return False
        if st.st_mode & 0o022:
            return False
        if path.parent.stat().st_mode & 0o022:
            return False
    except OSError:
        return False
    return True


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write("usage: refresh-claude-md <target.md> <manifest.toml>\n")
        return 64
    target_raw = Path(argv[1]).expanduser()
    manifest_raw = Path(argv[2]).expanduser()
    target = target_raw.resolve()
    manifest_path = manifest_raw.resolve()
    if not target.is_file():
        sys.stderr.write(f"target not found: {target}\n")
        return 66
    if not manifest_path.is_file():
        sys.stderr.write(f"manifest not found: {manifest_path}\n")
        return 66
    if not path_trusted(target_raw):
        audit("refresh_md_fail", target=str(target),
              reason="target_untrusted", detail=str(target_raw))
        sys.stderr.write(
            f"untrusted target (symlink, wrong owner, or writable by group/others): {target_raw}\n")
        return 2
    if not path_trusted(manifest_raw):
        audit("refresh_md_fail", target=str(target),
              reason="manifest_untrusted", detail=str(manifest_path))
        sys.stderr.write(
            f"untrusted manifest (symlink, wrong owner, or writable by group/others): {manifest_path}\n")
        return 2
    try:
        manifest = load_manifest(manifest_path)
    except (tomllib.TOMLDecodeError, OSError) as exc:
        audit("refresh_md_fail", target=str(target),
              reason="manifest_invalid", detail=type(exc).__name__)
        sys.stderr.write(f"invalid manifest: {exc}\n")
        return 2
    title = sanitize(str(manifest.get("title", DEFAULT_TITLE)))
    fields = manifest.get("field", [])
    if not isinstance(fields, list):
        audit("refresh_md_fail", target=str(target),
              reason="manifest_invalid", detail="field must be an array of tables")
        sys.stderr.write(
            "invalid manifest: 'field' must be an array of tables ([[field]]), "
            f"got {type(fields).__name__}\n")
        return 2
    try:
        target_text = target.read_text(encoding="utf-8")
    except OSError as exc:
        audit("refresh_md_fail", target=str(target),
              reason="read_failed", detail=type(exc).__name__)
        sys.stderr.write(f"read failed: {exc}\n")
        return 3
    try:
        locate_markers(target_text)
    except ValueError as exc:
        audit("refresh_md_fail", target=str(target),
              reason="missing_markers", detail=str(exc))
        sys.stderr.write(f"{exc}\n")
        return 1
    cwd = target.parent
    rows: list[tuple[str, str]] = []
    ok = 0
    failed = 0
    budget_hits = 0
    budget = resolve_budget()
    started = time.monotonic()
    for entry in fields:
        if not isinstance(entry, dict):
            continue
        label = sanitize(str(entry.get("label", "")))
        cmd = str(entry.get("command", "")).strip()
        default = sanitize(str(entry.get("default", "?")))
        if not label:
            failed += 1
            continue
        if not cmd:
            rows.append((label, default))
            failed += 1
            continue
        remaining = budget - (time.monotonic() - started)
        if remaining <= 0:
            rows.append((label, default))
            failed += 1
            budget_hits += 1
            continue
        value, success = run_field(cmd, default, cwd, min(TIMEOUT, remaining))
        rows.append((label, value))
        if success:
            ok += 1
        else:
            failed += 1
    block = render(title, rows)
    try:
        splice(target, block)
    except ValueError as exc:
        audit("refresh_md_fail", target=str(target),
              reason="missing_markers", detail=str(exc))
        sys.stderr.write(f"{exc}\n")
        return 1
    except OSError as exc:
        audit("refresh_md_fail", target=str(target),
              reason="write_failed", detail=type(exc).__name__)
        sys.stderr.write(f"write failed: {exc}\n")
        return 3
    sha = hashlib.sha256(target.read_bytes()).hexdigest()
    audit(
        "refresh_md", target=str(target), fields_ok=ok, fields_failed=failed,
        fields_budget_exhausted=budget_hits,
        elapsed_ms=int((time.monotonic() - started) * 1000), sha256=sha,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
