"""Exercise the shipped CLI against an isolated application-service fixture."""
import concurrent.futures
import json
import os
from pathlib import Path
import plistlib
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "build/PortBar.app/Contents/Helpers/portbar"
FIXTURE = ROOT / "build/tests/automation-tests"
with (ROOT / "build/PortBar.app/Contents/Info.plist").open("rb") as manifest:
    APP_VERSION = plistlib.load(manifest)["CFBundleShortVersionString"]
CLI_VERSION = subprocess.run([str(CLI), "--version"], capture_output=True, text=True, check=True).stdout
assert CLI_VERSION == f"portbar {APP_VERSION} (protocol 1)\n", "CLI and application versions must match"


def check(condition, message):
    if not condition:
        raise AssertionError(message)


with tempfile.TemporaryDirectory(prefix="portbar-ipc-", dir="/tmp") as directory:
    directory = Path(directory)
    env = dict(os.environ, PORTBAR_SOCKET=str(directory / "ipc/control.sock"))

    def cli(*args, payload=None, expected=0):
        result = subprocess.run(
            [str(CLI), *args, "--json"],
            input=json.dumps(payload) if payload is not None else None,
            capture_output=True, text=True, env=env, timeout=20,
        )
        response = json.loads(result.stdout)
        check(result.returncode == expected, f"{args}: exit {result.returncode}, {response}")
        check(not result.stderr, f"unexpected stderr: {result.stderr}")
        return response

    unavailable = cli("status", expected=3)
    check(unavailable["error"]["code"] == "APP_NOT_RUNNING", "unavailable app")
    cli("schema")
    cli("status", "--nonsense", expected=2)
    fixture = subprocess.Popen(
        [str(FIXTURE), "--serve", str(directory / "data")], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 5
        while not Path(env["PORTBAR_SOCKET"]).exists() and time.monotonic() < deadline:
            if fixture.poll() is not None:
                raise AssertionError(f"fixture failed: {fixture.communicate()}")
            time.sleep(0.02)
        capabilities = cli("capabilities")["data"]
        check(capabilities["protocolVersion"] == 1 and capabilities["cliVersion"] == APP_VERSION, "protocol and version discovery")
        check(Path(env["PORTBAR_SOCKET"]).stat().st_mode & 0o777 == 0o600, "socket permissions")
        check(Path(env["PORTBAR_SOCKET"]).parent.stat().st_mode & 0o777 == 0o700, "directory permissions")
        duplicate = subprocess.run(
            [str(FIXTURE), "--serve", str(directory / "duplicate-data")], env=env,
            capture_output=True, text=True, timeout=5,
        )
        check(duplicate.returncode == 1 and "ALREADY_RUNNING" in duplicate.stderr, "second server cannot replace socket")
        check(cli("status")["ok"], "original server still owns socket")

        preview = cli("hosts", "create", "--file", "-", "--dry-run", payload={"host": "localhost", "username": "ubuntu"})
        check(cli("hosts", "list")["data"] == [], "dry run did not save")
        created = cli("hosts", "create", "--file", "-", "--if-revision", preview["revision"], payload={"host": "localhost", "username": "ubuntu"})
        host_id = created["data"]["after"]["id"]
        check("password" not in created["data"]["after"], "no credential field")
        conflict = cli("hosts", "update", "--host-id", host_id, "--if-revision", preview["revision"], "--file", "-", payload={"name": "stale"}, expected=5)
        check(conflict["error"]["code"] == "REVISION_CONFLICT", "revision conflict across processes")
        cli("hosts", "create", "--file", "-", payload={"host": "localhost", "password": "never-expose"}, expected=2)
        cli("hosts", "list", "--limit", "9999", expected=2)

        with socket.socket() as temporary:
            temporary.bind(("127.0.0.1", 0))
            port = temporary.getsockname()[1]
        created_mapping = cli("mappings", "create", "--file", "-", payload={
            "hostId": host_id, "name": "integration-db", "portRules": [{"localPort": port, "remotePort": 3306}]
        })
        mapping_id = created_mapping["data"]["after"]["id"]
        check(cli("mappings", "list", "--search", "integration")["data"][0]["id"] == mapping_id, "mapping search")
        started = cli("tunnels", "start", "--mapping-id", mapping_id, "--wait", "--timeout", "5")
        check(started["data"]["state"] == "connected", "CLI waited for readiness")
        repeated = cli("tunnels", "start", "--mapping-id", mapping_id, "--wait")
        check(repeated["data"]["operationId"] == started["data"]["operationId"], "idempotent IPC start")
        diagnosed = cli("tunnels", "diagnose", "--mapping-id", mapping_id)
        check(diagnosed["data"]["ports"][0]["listening"], "diagnostic listener result")
        busy = cli("mappings", "update", "--mapping-id", mapping_id, "--file", "-", payload={"name": "busy"}, expected=5)
        check(busy["error"]["code"] == "RESOURCE_BUSY", "running configuration protected")
        stopped = cli("tunnels", "stop", "--mapping-id", mapping_id, "--wait")
        check(stopped["data"]["state"] == "disconnected", "CLI waited for stop")

        cli("hosts", "update", "--host-id", host_id, "--file", "-", payload={"host": "slow.test"})
        timed_out = cli("tunnels", "start", "--mapping-id", mapping_id, "--wait", "--timeout", "1", expected=6)
        check(timed_out["error"]["code"] == "TIMEOUT", "wait timeout is explicit")
        cli("tunnels", "stop", "--mapping-id", mapping_id, "--wait")
        waiting = subprocess.Popen(
            [str(CLI), "tunnels", "start", "--mapping-id", mapping_id, "--wait", "--json"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if cli("tunnels", "status", "--mapping-id", mapping_id)["data"]["state"] == "connecting":
                break
            time.sleep(0.02)
        cli("tunnels", "stop", "--mapping-id", mapping_id, "--wait")
        superseded, stderr = waiting.communicate(timeout=5)
        check(waiting.returncode == 5 and not stderr and json.loads(superseded)["error"]["code"] == "OPERATION_SUPERSEDED", "wait detects replacement even after desired state changes")
        cli("hosts", "update", "--host-id", host_id, "--file", "-", payload={"host": "auth-failure.test"})
        failed = cli("tunnels", "start", "--mapping-id", mapping_id, "--wait", expected=5)
        check(failed["error"]["code"] == "AUTH_FAILED", "CLI failed start has structured cause")
        cli("tunnels", "stop", "--mapping-id", mapping_id, "--wait")

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: cli("status"), range(8)))
        check(all(item["ok"] for item in results), "concurrent clients share service")
        time.sleep(5.2)
        check(cli("status")["ok"], "server survives idle period")

        with socket.socket(socket.AF_UNIX) as raw:
            raw.settimeout(5)
            raw.connect(env["PORTBAR_SOCKET"])
            raw.sendall(b"invalid-json\n")
            check(not json.loads(raw.recv(8192))["ok"], "malformed IPC request rejected")
        cli("status")
        cli("logs", "list", "--mapping-id", mapping_id, "--limit", "10")
        cli("activity", "list", "--limit", "10")
        cli("hosts", "delete", "--host-id", host_id, expected=5)
        cascade = cli("hosts", "delete", "--host-id", host_id, "--cascade", "--dry-run")
        check(cascade["data"]["affectedMappingIds"] == [mapping_id], "cascade preview")
        cli("hosts", "delete", "--host-id", host_id, "--cascade", "--if-revision", cascade["revision"])
        check(cli("mappings", "list")["data"] == [], "cascade removed mapping")
        config = directory / "data/config_v2.json"
        check(config.stat().st_mode & 0o777 == 0o600, "private configuration permissions")

        installed = cli("skill", "install", "--directory", str(directory / "skills"))
        check(Path(installed["data"]["installed"]).joinpath("SKILL.md").is_file(), "bundled skill install")
        cli("skill", "install", "--directory", str(directory / "skills"), expected=5)
    finally:
        os.killpg(fixture.pid, signal.SIGTERM)
        fixture.communicate(timeout=5)

print("PASS: packaged CLI, IPC, concurrency, wait/error exit codes, private files and bundled Skill")
