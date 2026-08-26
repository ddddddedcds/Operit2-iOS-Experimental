#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


RUNTIME_DIR = Path(__file__).resolve().parent
SOURCE_DIR = RUNTIME_DIR / "sources"
ISH_DIR = SOURCE_DIR / "ish"

# A2: OpenMinis/ish-arm64 — `kernel=ish` + arm64 guest.
# This is the App Store-compatible iSH configuration (userspace emulator that
# runs a real aarch64 Linux userspace). It replaces the previous ish-app/ish
# `kernel=linux` checkout, whose real-Linux-kernel embed panics inside the iOS
# app sandbox and was the root cause of "selecting iSH crashes the app".
ISH_REPO = "https://github.com/OpenMinis/ish-arm64.git"
ISH_BRANCH = "feature-arm64"
# Pinned to a known-good feature-arm64 commit (verified reachable 2026-08-26).
ISH_PINNED_COMMIT = "54ca185b77f170e12fd353fcd7443232f6cb73fd"


def run(cmd, cwd=None):
    print(f"+ {' '.join(cmd)}", flush=True)
    subprocess.run(cmd, cwd=cwd, check=True)


def current_head() -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(ISH_DIR), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except Exception:
        return ""


def prepare_ish_sources() -> None:
    if ISH_DIR.exists() and current_head() != ISH_PINNED_COMMIT:
        head = current_head()
        print(f"Removing stale iSH source (head={head[:12] or 'none'})", flush=True)
        shutil.rmtree(ISH_DIR)

    if not ISH_DIR.exists():
        ISH_DIR.parent.mkdir(parents=True, exist_ok=True)
        run([
            "git", "clone", "--recursive", "--branch", ISH_BRANCH,
            "--single-branch", ISH_REPO, str(ISH_DIR),
        ])
        run(["git", "-C", str(ISH_DIR), "checkout", ISH_PINNED_COMMIT])
        run(["git", "-C", str(ISH_DIR), "submodule", "update", "--init", "--recursive"])
    else:
        # Already at the pinned commit — make sure submodules are present.
        run(["git", "-C", str(ISH_DIR), "submodule", "update", "--init", "--recursive"])

    head = current_head()
    if head != ISH_PINNED_COMMIT:
        raise RuntimeError(
            f"iSH source HEAD {head} != pinned {ISH_PINNED_COMMIT}"
        )


def main() -> int:
    prepare_ish_sources()
    print(f"iSH source: {ISH_DIR}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
