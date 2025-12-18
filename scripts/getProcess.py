#!/usr/bin/env python3
"""
Capture ALL system INET network sockets (TCP/UDP) in real time, excluding specific PIDs.
App_name is ONLY used to name the output file: <App_name>.csv

Default mode: delta (NEW/UPDATE/CLOSE events)
Optional mode: snapshot (log every socket every interval)

CSV columns:
timestamp, event, pid, process_name, exe, username, protocol, family,
host_address, host_port, remote_address, remote_port, status
"""

import argparse
import csv
import os
import re
import socket
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Dict, Iterable, Optional, Set, Tuple

import psutil


def safe_filename(name: str) -> str:
    name = (name or "").strip() or "output"
    base = re.sub(r'[\\/*?:"<>|]+', "_", name)
    base = re.sub(r"\s+", "_", base)
    return f"{base}.csv"


def now_iso_local() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def parse_pid_list(s: str) -> Set[int]:
    out: Set[int] = set()
    s = (s or "").strip()
    if not s:
        return out
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            out.add(int(part))
        except ValueError:
            print(f"Warning: ignoring invalid PID '{part}'", file=sys.stderr)
    return out


def ensure_header(path: str, header: Iterable[str]) -> None:
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        with open(path, "w", newline="", encoding="utf-8") as f:
            csv.writer(f).writerow(list(header))
            f.flush()
            os.fsync(f.fileno())


def addr_to_host_port(addr) -> Tuple[str, int]:
    """addr can be (), None, a tuple, or psutil addr object with .ip/.port"""
    if not addr:
        return ("", 0)
    try:
        return (addr.ip, int(addr.port))
    except AttributeError:
        return (str(addr[0]), int(addr[1]))


def family_to_str(fam: Optional[int]) -> str:
    if fam == socket.AF_INET:
        return "IPv4"
    if fam == socket.AF_INET6:
        return "IPv6"
    return str(fam) if fam is not None else ""


def proto_to_str(sock_type: Optional[int]) -> str:
    if sock_type == socket.SOCK_STREAM:
        return "TCP"
    if sock_type == socket.SOCK_DGRAM:
        return "UDP"
    return str(sock_type) if sock_type is not None else ""


@dataclass(frozen=True)
class ConnKey:
    pid: Optional[int]
    family: str
    protocol: str
    laddr: str
    lport: int
    raddr: str
    rport: int


@dataclass
class ConnInfo:
    pid: Optional[int]
    process_name: str
    exe: str
    username: str
    protocol: str
    family: str
    host_address: str
    host_port: int
    remote_address: str
    remote_port: int
    status: str


class ProcCache:
    """Small process metadata cache with TTL to reduce repeated psutil calls."""
    def __init__(self, ttl_seconds: float = 10.0):
        self.ttl = ttl_seconds
        self._data: Dict[int, Tuple[float, Tuple[str, str, str]]] = {}  # pid -> (t, (name, exe, user))

    def get(self, pid: Optional[int]) -> Tuple[str, str, str]:
        if pid is None or pid <= 0:
            return ("", "", "")
        now = time.time()
        hit = self._data.get(pid)
        if hit and (now - hit[0]) <= self.ttl:
            return hit[1]

        name = exe = user = ""
        try:
            p = psutil.Process(pid)
            try:
                name = p.name() or ""
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                name = ""
            try:
                exe = p.exe() or ""
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                exe = ""
            try:
                user = p.username() or ""
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                user = ""
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass

        self._data[pid] = (now, (name, exe, user))
        return (name, exe, user)


def snapshot_conns(exclude_pids: Set[int], pcache: ProcCache) -> Dict[ConnKey, ConnInfo]:
    out: Dict[ConnKey, ConnInfo] = {}

    conns = psutil.net_connections(kind="inet")
    for c in conns:
        pid = getattr(c, "pid", None)
        if pid is not None and pid in exclude_pids:
            continue

        laddr, lport = addr_to_host_port(getattr(c, "laddr", None))
        raddr, rport = addr_to_host_port(getattr(c, "raddr", None))

        # If there's no local endpoint, it's not very actionable for logging
        if not laddr or not lport:
            continue

        fam = family_to_str(getattr(c, "family", None))
        proto = proto_to_str(getattr(c, "type", None))
        status = str(getattr(c, "status", "") or "")

        pname, exe, user = pcache.get(pid)

        key = ConnKey(
            pid=pid,
            family=fam,
            protocol=proto,
            laddr=laddr,
            lport=lport,
            raddr=raddr,
            rport=rport,
        )
        out[key] = ConnInfo(
            pid=pid,
            process_name=pname,
            exe=exe,
            username=user,
            protocol=proto,
            family=fam,
            host_address=laddr,
            host_port=lport,
            remote_address=raddr,
            remote_port=rport,
            status=status,
        )

    return out


def write_row(writer: csv.writer, f, ts: str, event: str, info: ConnInfo) -> None:
    writer.writerow([
        ts,
        event,
        info.pid if info.pid is not None else "",
        info.process_name,
        info.exe,
        info.username,
        info.protocol,
        info.family,
        info.host_address,
        info.host_port,
        info.remote_address,
        info.remote_port,
        info.status,
    ])
    f.flush()
    os.fsync(f.fileno())


def info_changed(a: ConnInfo, b: ConnInfo) -> bool:
    # Detect meaningful changes
    return (
        a.status != b.status
        or a.process_name != b.process_name
        or a.exe != b.exe
        or a.username != b.username
    )


def conn_row_key(info: ConnInfo) -> Tuple[Optional[int], str, str, str, str, str, str, int, str, int]:
    return (
        info.pid,
        info.process_name,
        info.exe,
        info.username,
        info.protocol,
        info.family,
        info.host_address,
        info.host_port,
        info.remote_address,
        info.remote_port,
    )


def main():
    parser = argparse.ArgumentParser(description="Capture all system network sockets to CSV.")
    parser.add_argument("--app-name", required=True, help="Used only to name the output: <app-name>.csv")
    parser.add_argument("--exclude-pids", default="", help="Comma-separated PIDs to exclude (e.g. 1234,5678).")
    parser.add_argument("--interval", type=float, default=0.1, help="Polling interval seconds (default: 1.0).")
    parser.add_argument(
        "--mode",
        choices=["delta", "snapshot"],
        default="snapshot",
        help="delta: log NEW/UPDATE/CLOSE (default). snapshot: log everything every poll.",
    )
    parser.add_argument(
        "--proc-cache-ttl",
        type=float,
        default=10.0,
        help="Seconds to cache process metadata (default: 10.0).",
    )
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    parent_dir = os.path.abspath(os.path.join(script_dir, os.pardir))
    log_dir = os.path.join(parent_dir, "process_logs")
    os.makedirs(log_dir, exist_ok=True)

    out_path = os.path.join(log_dir, safe_filename(args.app_name))
    exclude_pids = parse_pid_list(args.exclude_pids)
    exclude_pids.add(0)
    interval = max(0.1, float(args.interval))
    mode = args.mode

    header = [
        "timestamp",
        "event",
        "pid",
        "process_name",
        "exe",
        "username",
        "protocol",
        "family",
        "host_address",
        "host_port",
        "remote_address",
        "remote_port",
        "status",
    ]
    ensure_header(out_path, header)

    pcache = ProcCache(ttl_seconds=max(1.0, float(args.proc_cache_ttl)))

    print(f"Output: {out_path}")
    print(f"Mode: {mode}")
    print(f"Excluding PIDs: {sorted(exclude_pids) if exclude_pids else 'None'}")
    print("Press Ctrl+C to stop.\n")

    prev: Dict[ConnKey, ConnInfo] = {}
    seen_keys: Set[Tuple[Optional[int], str, str, str, str, str, str, int, str, int]] = set()
    warned_access = False

    try:
        with open(out_path, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)

            while True:
                ts = now_iso_local()
                try:
                    cur = snapshot_conns(exclude_pids, pcache)
                except psutil.AccessDenied:
                    if not warned_access:
                        print(
                            "AccessDenied: run as Administrator/root for full PID/process visibility.",
                            file=sys.stderr,
                        )
                        warned_access = True
                    cur = {}  # keep loop alive
                except Exception as e:
                    # Keep running no matter what; log to stderr and continue.
                    print(f"Error reading connections: {e}", file=sys.stderr)
                    cur = {}

                if mode == "snapshot":
                    for info in cur.values():
                        key = conn_row_key(info)
                        if key in seen_keys:
                            continue
                        seen_keys.add(key)
                        write_row(writer, f, ts, "SNAPSHOT", info)
                else:
                    # NEW + UPDATE
                    for k, info in cur.items():
                        if k not in prev:
                            key = conn_row_key(info)
                            if key in seen_keys:
                                continue
                            seen_keys.add(key)
                            write_row(writer, f, ts, "NEW", info)
                        else:
                            if info_changed(prev[k], info):
                                key = conn_row_key(info)
                                if key not in seen_keys:
                                    seen_keys.add(key)
                                    write_row(writer, f, ts, "UPDATE", info)

                    # CLOSE (things that disappeared since last poll)
                    for k, old_info in prev.items():
                        if k not in cur:
                            key = conn_row_key(old_info)
                            if key in seen_keys:
                                continue
                            seen_keys.add(key)
                            write_row(writer, f, ts, "CLOSE", old_info)

                prev = cur
                time.sleep(interval)

    except KeyboardInterrupt:
        print("\nStopped by user.")


if __name__ == "__main__":
    main()
