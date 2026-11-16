#!/usr/bin/env python3
"""SEC32 spike probe: is zero egress enforceable in the kernel for the `mp` child?

Owner-run and read-only. It changes no production code, reads no library, writes
nothing outside a scratch directory it removes, and sends nothing to any service:
the only outbound attempts are the ten planted ones below, aimed at a canary in
the reserved TEST-NET-1 block (192.0.2.0/24, which no network routes), plus two DNS
lookups (one fixed control name, one unique name). Safe to run during a real meeting.

It runs each planted bypass twice, in a fresh process each time:

  armed-only   the in-process egress guard armed (`mp.egress_guard.arm()`), no sandbox.
               This is today's enforcement and the baseline: it should block the httpx
               cases and nothing else, which is SEC19's whole point.
  profile      NO guard, run under `sandbox-exec` with a profile denying every
               non-loopback connection. The kernel alone is the enforcement.

A case counts as BLOCKED under the profile only when the attempt itself failed with
EPERM ("Operation not permitted"), which is what a sandbox deny returns, as opposed to
ECONNREFUSED, ENETUNREACH, a timeout or success, all of which mean the connect left the
process unimpeded. A `sys.addaudithook` recorder is the second witness: it proves the
attempt was actually made, so "never tried" cannot read as "blocked".

Run from the pipeline venv so httpx and requests import:

    cd pipeline && uv run python scripts/sec32_kernel_egress_probe.py

Optional legs (each prints NOT RUN without its flag):

    --transcript PATH   run the golden local summary open and under the profile with
                        docs/spikes/local12_bench.py (needs the local model cached);
                        reports schema validity and the wall-time overhead.

The verdict thresholds are pre-registered in docs/spikes/sec32-kernel-zero-egress.md and
are repeated, unchanged, in the READ line this prints. Do not edit them after a run.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import ctypes
import errno
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

#: TEST-NET-1 (RFC 5737): reserved, never routed. Not this Mac's own interface address, which a
#: loopback-only profile still admits (the 2026-11-12 judge's finding), so it can discriminate.
CANARY = "192.0.2.1"
CANARY_PROXY = "192.0.2.2"
CANARY_PORT = 9
ATTEMPT_TIMEOUT = 2.0

#: The profile under test. Every clause is load-bearing: the judge found that one extra allow made
#: an earlier profile silently permissive, so this is printed verbatim in the report and any edit is
#: a new measurement. `allow default` keeps the interpreter, the venv and Metal working; the deny
#: and the single loopback allow are the whole policy.
PROFILE = (
    "(version 1)\n"
    "(allow default)\n"
    "(deny network-outbound)\n"
    '(allow network-outbound (remote ip "localhost:*"))\n'
)

SANDBOX_EXEC = "/usr/bin/sandbox-exec"

CASES = (
    "httpx_direct",
    "httpx_proxy_env",
    "urllib",
    "requests",
    "raw_socket",
    "asyncio_stream",
    "ctypes_connect",
    "child_curl",
    "child_python",
    "dns_lookup",
)

#: Not one of the ten and not counted: a positive control. The profile must still let the process
#: talk to itself over loopback (the local model server and its client do), or "10 of 10 blocked"
#: would be a profile that blocks everything and breaks the summary.
LOOPBACK_CONTROL = "loopback_control"

DNS_CONTROL_NAME = "example.com"


# --------------------------------------------------------------------------- case side

def _classify(exc: BaseException | None) -> str:
    """What the attempt itself says: kernel_blocked, guard_blocked, reached_network."""
    if exc is None:
        return "reached_network"
    if type(exc).__name__ == "EgressBlocked":
        return "guard_blocked"
    seen: BaseException | None = exc
    while seen is not None:
        if isinstance(seen, OSError) and seen.errno in (errno.EPERM, errno.EACCES):
            return "kernel_blocked"
        if "operation not permitted" in str(seen).lower():
            return "kernel_blocked"
        seen = seen.__cause__ or seen.__context__
    return "reached_network"


def _attempt_connect() -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(ATTEMPT_TIMEOUT)
    try:
        s.connect((CANARY, CANARY_PORT))
    finally:
        s.close()


def _case_body(name: str) -> tuple[str, str]:
    """Run one planted bypass. Returns (outcome, detail). Raises nothing the caller must handle."""
    try:
        if name == "httpx_direct":
            import httpx

            httpx.get(f"http://{CANARY}:{CANARY_PORT}/", timeout=ATTEMPT_TIMEOUT)
        elif name == "httpx_proxy_env":
            import httpx

            os.environ["HTTP_PROXY"] = f"http://{CANARY_PROXY}:3128"
            httpx.get("http://sec32-target.invalid/", timeout=ATTEMPT_TIMEOUT)
        elif name == "urllib":
            import urllib.request

            urllib.request.urlopen(f"http://{CANARY}:{CANARY_PORT}/", timeout=ATTEMPT_TIMEOUT)  # noqa: S310
        elif name == "requests":
            import requests

            requests.get(f"http://{CANARY}:{CANARY_PORT}/", timeout=ATTEMPT_TIMEOUT)
        elif name == "raw_socket":
            _attempt_connect()
        elif name == "asyncio_stream":
            asyncio.run(asyncio.wait_for(asyncio.open_connection(CANARY, CANARY_PORT), ATTEMPT_TIMEOUT))
        elif name == "ctypes_connect":
            _ctypes_connect()
        elif name == "child_curl":
            return _child(["/usr/bin/curl", "-sSv", "-m", str(int(ATTEMPT_TIMEOUT)), f"http://{CANARY}:{CANARY_PORT}/"])
        elif name == "child_python":
            code = (
                "import socket;s=socket.socket();s.settimeout(%s);s.connect(('%s',%d))"
                % (ATTEMPT_TIMEOUT, CANARY, CANARY_PORT)
            )
            return _child([sys.executable, "-c", code])
        elif name == "dns_lookup":
            return _dns()
        elif name == LOOPBACK_CONTROL:
            with socket.socket() as srv:
                srv.bind(("127.0.0.1", 0))
                srv.listen(1)
                with socket.create_connection(srv.getsockname(), timeout=ATTEMPT_TIMEOUT):
                    pass
        else:
            return "error", f"unknown case {name}"
    except Exception as exc:  # noqa: BLE001 - the classification is the point
        return _classify(exc), f"{type(exc).__name__}: {exc}"[:200]
    return "reached_network", "completed without an error"


def _ctypes_connect() -> None:
    """libc connect() straight through ctypes, bypassing every Python-level socket layer."""
    libc = ctypes.CDLL(None, use_errno=True)
    fd = libc.socket(socket.AF_INET, socket.SOCK_STREAM, 0)
    if fd < 0:
        raise OSError(ctypes.get_errno(), "socket() failed")

    class SockAddrIn(ctypes.Structure):
        _fields_ = [
            ("sin_len", ctypes.c_uint8),
            ("sin_family", ctypes.c_uint8),
            ("sin_port", ctypes.c_uint16),
            ("sin_addr", ctypes.c_uint8 * 4),
            ("sin_zero", ctypes.c_uint8 * 8),
        ]

    addr = SockAddrIn()
    addr.sin_len = ctypes.sizeof(SockAddrIn)
    addr.sin_family = socket.AF_INET
    addr.sin_port = socket.htons(CANARY_PORT)
    addr.sin_addr = (ctypes.c_uint8 * 4)(*socket.inet_aton(CANARY))
    # Non-blocking so an unrouted address returns EINPROGRESS at once instead of blocking for
    # the kernel's connect timeout (ctypes cannot call the variadic fcntl safely on arm64).
    os.set_blocking(fd, False)
    rc = libc.connect(fd, ctypes.byref(addr), ctypes.sizeof(addr))
    err = ctypes.get_errno()
    libc.close(fd)
    if rc != 0 and err not in (errno.EINPROGRESS,):
        raise OSError(err, os.strerror(err))


def _child(argv: list[str]) -> tuple[str, str]:
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=ATTEMPT_TIMEOUT + 3, check=False)  # noqa: S603
    except (OSError, subprocess.SubprocessError) as exc:
        return "error", f"{type(exc).__name__}: {exc}"[:200]
    text = (proc.stderr + proc.stdout).strip()
    if "operation not permitted" in text.lower():
        return "kernel_blocked", text[:200]
    return "reached_network", f"exit {proc.returncode}: {text[:160]}"


def _dns() -> tuple[str, str]:
    """A control name that resolves anywhere with a network, and a unique name nobody has asked
    for. The unique lookup alone cannot tell "blocked" from "NXDOMAIN", so the verdict reads the
    control: blocked only if it fails here yet resolved in the armed-only baseline."""
    unique = f"sec32-{uuid.uuid4().hex[:12]}.example.com"
    try:
        socket.getaddrinfo(DNS_CONTROL_NAME, 80)
        control = "resolved"
    except OSError as exc:
        control = f"failed ({exc})"
    try:
        socket.getaddrinfo(unique, 80)
        unique_result = "resolved"
    except OSError as exc:
        unique_result = f"failed ({exc})"
    outcome = "reached_network" if control == "resolved" else "dns_failed"
    return outcome, f"control {DNS_CONTROL_NAME}: {control}; unique name: {unique_result}"


def run_case(name: str, armed: bool) -> int:
    witness: list[str] = []

    def hook(event: str, args: tuple) -> None:
        if event == "socket.connect":
            witness.append(str(args[1]))
        elif event == "socket.getaddrinfo":
            witness.append(f"dns:{args[0]}")

    sys.addaudithook(hook)
    if armed:
        from mp import egress_guard

        egress_guard.arm("sec32 probe")
    outcome, detail = _case_body(name)
    print(json.dumps({"case": name, "outcome": outcome, "detail": detail, "witness": witness[:6]}))
    return 0


# ------------------------------------------------------------------------- driver side

def _run_case_process(name: str, *, sandboxed: bool, armed: bool) -> dict:
    cmd = [sys.executable, str(Path(__file__).resolve()), "--case", name]
    if armed:
        cmd.append("--armed")
    if sandboxed:
        cmd = [SANDBOX_EXEC, "-p", PROFILE, *cmd]
    started = time.monotonic()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)  # noqa: S603
    except (OSError, subprocess.SubprocessError) as exc:
        return {"case": name, "outcome": "error", "detail": f"{type(exc).__name__}: {exc}"[:200], "witness": []}
    for line in reversed(proc.stdout.strip().splitlines()):
        with contextlib.suppress(json.JSONDecodeError):
            result = json.loads(line)
            result["seconds"] = round(time.monotonic() - started, 2)
            return result
    tail = (proc.stderr or proc.stdout).strip().splitlines()[-1:] or [""]
    return {"case": name, "outcome": "error", "detail": f"exit {proc.returncode}: {tail[0][:160]}", "witness": []}


def _sandbox_exec_works() -> tuple[bool, str]:
    if not os.access(SANDBOX_EXEC, os.X_OK):
        return False, f"{SANDBOX_EXEC} is missing"
    try:
        proc = subprocess.run(  # noqa: S603
            [SANDBOX_EXEC, "-p", PROFILE, "/usr/bin/true"], capture_output=True, text=True, timeout=15, check=False
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"{type(exc).__name__}: {exc}"
    if proc.returncode != 0:
        return False, f"exit {proc.returncode}: {(proc.stderr or proc.stdout).strip()[:200]}"
    return True, "ok"


def _cloudsync_leg() -> tuple[bool, str]:
    """The storage check, against a scratch home with a planted synced-folder marker. A kernel deny
    cannot see a file the sync client uploads from underneath, so this must say 'not confined'."""
    from mp.cloudsync import detect_sync_provider

    scratch = Path(tempfile.mkdtemp(prefix="sec32-home-"))
    try:
        library = scratch / "Library" / "CloudStorage" / "Dropbox-sec32" / "Meetings"
        library.mkdir(parents=True)
        provider = detect_sync_provider(library, home=scratch)
        if provider is None:
            return False, "the planted synced folder was NOT reported as synced"
        return True, f"reported as synced by {provider.name} (so: not confined)"
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def _summary_leg(transcript: Path) -> tuple[bool | None, float | None, str]:
    """Golden local summary, open then under the profile, via the production-path bench. Returns
    (schema_valid_under_profile, overhead_percent, detail)."""
    bench = Path(__file__).resolve().parents[2] / "docs" / "spikes" / "local12_bench.py"
    runs = Path(tempfile.mkdtemp(prefix="sec32-runs-"))
    try:
        timings: dict[str, float] = {}
        valid: bool | None = None
        detail = ""
        for label, sandboxed in (("open", False), ("profile", True)):
            cmd = [sys.executable, str(bench), "--transcript", str(transcript), "--runs", "1",
                   "--label", f"sec32-{label}", "--runs-dir", str(runs)]
            if sandboxed:
                cmd = [SANDBOX_EXEC, "-p", PROFILE, *cmd]
            started = time.monotonic()
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=1800, check=False)  # noqa: S603
            timings[label] = time.monotonic() - started
            if proc.returncode != 0:
                return False if sandboxed else None, None, f"{label} run exit {proc.returncode}: {proc.stderr.strip()[-200:]}"
        out = runs / "local12-sec32-profile.summary.json"
        try:
            from mp.schemas import MeetingSummary

            MeetingSummary.model_validate_json(out.read_text(encoding="utf-8"))
            valid = True
        except Exception as exc:  # noqa: BLE001
            valid = False
            detail = f"summary under the profile did not validate: {type(exc).__name__}: {exc}"[:200]
        overhead = (timings["profile"] - timings["open"]) / timings["open"] * 100 if timings["open"] else None
        return valid, overhead, detail or f"open {timings['open']:.1f}s, profile {timings['profile']:.1f}s"
    finally:
        shutil.rmtree(runs, ignore_errors=True)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="SEC32 kernel zero-egress probe (owner-run, read-only).")
    p.add_argument("--case", choices=(*CASES, LOOPBACK_CONTROL), help=argparse.SUPPRESS)
    p.add_argument("--armed", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--transcript", type=Path, help="golden transcript .md for the local-summary leg")
    args = p.parse_args(argv)
    if args.case:
        return run_case(args.case, args.armed)

    print("SEC32 kernel zero-egress probe (read-only; canary is the unrouted TEST-NET-1 block)\n")
    print("PROFILE under test (verbatim; any edit is a new measurement):")
    for line in PROFILE.splitlines():
        print(f"    {line}")
    works, why = _sandbox_exec_works()
    print(f"\nsandbox-exec: {'works' if works else 'REFUSES'} ({why})")
    if not works:
        print("\nREAD: FAIL. sandbox-exec refuses on this macOS (pre-registered FAIL condition); fall back to SEC19's in-process layer.")
        return 1

    armed: dict[str, dict] = {}
    sandbox: dict[str, dict] = {}
    print("\nrunning each planted bypass: armed-only, then under the profile (about 2 s each)\n")
    for name in CASES:
        armed[name] = _run_case_process(name, sandboxed=False, armed=True)
        sandbox[name] = _run_case_process(name, sandboxed=True, armed=False)

    print(f"{'case':<18}{'armed-only guard':<20}{'kernel profile':<20}witness under the profile")
    blocked = 0
    baseline_ok = armed["dns_lookup"]["outcome"] == "reached_network"
    for name in CASES:
        a, s = armed[name], sandbox[name]
        is_blocked = s["outcome"] == "kernel_blocked" or (
            name == "dns_lookup" and baseline_ok and s["outcome"] == "dns_failed"
        )
        blocked += is_blocked
        print(f"{name:<18}{a['outcome']:<20}{('BLOCKED' if is_blocked else s['outcome']):<20}{s.get('witness') or '-'}")
        if not is_blocked or name == "dns_lookup":
            print(f"{'':<18}detail: {s.get('detail', '')}")
    guard_blocked = sum(1 for a in armed.values() if a["outcome"] == "guard_blocked")
    print(f"\narmed-only baseline: {guard_blocked}/10 blocked by the in-process guard (SEC19's gap is the rest)")
    print(f"under the profile:   {blocked}/10 blocked in the kernel")
    if not baseline_ok:
        print("NOTE: the DNS control did not resolve in the baseline, so this Mac may be offline; "
              "the DNS case cannot be read. Reconnect and rerun for a clean measurement.")

    loop = _run_case_process(LOOPBACK_CONTROL, sandboxed=True, armed=False)
    loopback_ok = loop["outcome"] == "reached_network"
    print(f"loopback control under the profile (must connect): {'ok' if loopback_ok else 'FAILED, ' + loop.get('detail', '')}")

    storage_ok, storage_detail = _cloudsync_leg()
    print(f"storage check on a planted synced folder: {storage_detail}")

    if args.transcript:
        valid, overhead, detail = _summary_leg(args.transcript)
        print(f"golden local summary under the profile: valid={valid} overhead={'n/a' if overhead is None else f'{overhead:.1f}%'} ({detail})")
    else:
        valid, overhead = None, None
        print("golden local summary under the profile: NOT RUN (pass --transcript PATH)")

    bypassing = [n for n in CASES if sandbox[n]["outcome"] != "kernel_blocked" and not (
        n == "dns_lookup" and baseline_ok and sandbox[n]["outcome"] == "dns_failed")]
    if not loopback_ok:
        verdict = "NOT PASS: the profile blocks loopback, so the local model server could not run under it. Tune the profile; if no profile keeps loopback and blocks the rest, that is the FAIL condition."
    elif blocked == 10 and storage_ok and valid and overhead is not None and overhead < 5:
        verdict = "PASS: 10/10 blocked, golden summary valid, overhead under 5%, planted synced folder reported as not confined. Build the re-exec wrap."
    elif blocked == 10 and storage_ok and valid is None:
        verdict = "PASS PENDING: 10/10 blocked and the storage check holds, but the golden-summary leg was not run; rerun with --transcript."
    elif valid is False:
        verdict = "NOT PASS: the golden local summary did not complete under the profile. Tune the profile (2 day budget); if MLX or the loopback server cannot run under it, that is the FAIL condition."
    elif overhead is not None and overhead >= 5:
        verdict = f"NOT PASS: overhead {overhead:.1f}% is not under 5%."
    else:
        verdict = f"NOT PASS: {10 - blocked} bypass(es) not blocked in the kernel ({', '.join(bypassing) or 'storage check'}). Tune the profile within the 2 day budget; a bypass no profile closes is the FAIL condition."
    print(f"\nREAD: {verdict}")
    print("(thresholds pre-registered in docs/spikes/sec32-kernel-zero-egress.md; a kernel deny cannot see the policy-layer leaks, file-mediated egress, or the unconfined daemon)")
    return 0 if verdict.startswith("PASS") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
