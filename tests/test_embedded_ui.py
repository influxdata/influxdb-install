#!/usr/bin/env python3
"""Test generated Compose and real Enterprise authentication. Requires Docker.

Provide INFLUXDB3_LICENSE (JWT content) or INFLUXDB3_TEST_LICENSE_FILE.
The test never requests a license or prints credentials. See tests/README.md.
"""

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


REPO = Path(__file__).resolve().parent.parent
SERVICE = "influxdb3-enterprise"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(args, *, env=None, cwd=None):
    result = subprocess.run(
        args, env=env, cwd=cwd, text=True, capture_output=True, timeout=300
    )
    # Output can contain the license, generated token or temporary password.
    require(result.returncode == 0, f"{args[0]} {args[1]} failed (exit {result.returncode})")
    return result.stdout


def request(url, *, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def wait_ready(url, container):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            # /health requires a token when authentication is enabled.
            # Explorer's public entry page becomes ready with the listener.
            status, page = request(url + "/")
            if status == 200 and b"<html" in page.lower():
                return
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            pass
        state = command(["docker", "inspect", "--format", "{{.State.Status}}", container]).strip()
        require(state == "running", f"Enterprise container stopped during startup ({state})")
        time.sleep(1)
    raise RuntimeError("Enterprise did not become healthy within 120 seconds")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_version = re.search(
        r'^INFLUXDB_ENT_VERSION="?([0-9.]+)',
        (REPO / "install_influxdb.sh").read_text(), re.MULTILINE
    ).group(1)
    parser.add_argument("--version", default=default_version)
    parser.add_argument("--keep", action="store_true", help="Keep the test container and files for inspection")
    args = parser.parse_args()
    require(re.fullmatch(r"3\.\d+\.\d+", args.version), "Use a final 3.Y.Z version")

    license_content = os.environ.get("INFLUXDB3_LICENSE", "")
    if not license_content:
        license_path = os.environ.get("INFLUXDB3_TEST_LICENSE_FILE")
        require(license_path, "Set INFLUXDB3_LICENSE or INFLUXDB3_TEST_LICENSE_FILE")
        license_content = Path(license_path).read_text()
    require(license_content.strip(), "The supplied license is empty")
    command(["docker", "info"])
    command(["docker", "compose", "version"])
    image = f"influxdb:{args.version}-enterprise"
    print(f"Testing {image}", flush=True)
    command(["docker", "pull", image])

    test_dir = Path(tempfile.mkdtemp(prefix="influxdb-install-auth-"))
    project = "install-auth-" + secrets.token_hex(5)
    container = project + "-server"
    volume = project + "-data"
    env = dict(os.environ)
    # Only the explicit license file reaches the server.
    env.pop("INFLUXDB3_LICENSE", None)
    env.update(TEST_REPO=str(REPO), TEST_DIR=str(test_dir),
               TEST_VERSION=args.version, TEST_CONTAINER=container)
    helper = ["sh", str(REPO / "tests/embedded_ui_helpers.sh")]
    compose_file = test_dir / "compose.json"
    compose = ["docker", "compose", "-p", project, "-f", str(compose_file)]
    started = False
    try:
        license_file = test_dir / "license.jwt"
        license_file.write_text(license_content)
        license_file.chmod(0o600)
        command(helper + ["configure"], env=env)
        before = (test_dir / ".env").read_bytes()
        generated = json.loads(command(
            ["docker", "compose", "-p", project, "-f", str(test_dir / "docker-compose.yml"),
             "config", "--format", "json"], env=env, cwd=test_dir
        ))
        require(set(generated["services"]) == {SERVICE}, "Generated stack must contain only the embedded server")
        service = generated["services"][SERVICE]
        # Preserve generated flags and auth environment. Isolate names, ports,
        # storage and licensing from the developer's installed stack.
        service["container_name"] = container
        service["ports"] = [{"target": 8181, "published": "0", "host_ip": "127.0.0.1", "protocol": "tcp"}]
        service["restart"] = "no"
        service["environment"].pop("INFLUXDB3_LICENSE_EMAIL", None)
        service["environment"]["INFLUXDB3_LICENSE_FILE"] = "/test-license/license.jwt"
        service["environment"]["INFLUXDB3_NUM_CORES"] = "2"
        plugins = test_dir / "plugins"
        plugins.mkdir()
        # Docker volumes avoid macOS bind-mount file-lock failures.
        service["volumes"] = [
            {"type": "volume", "source": "test-data", "target": "/var/lib/influxdb3/data"},
            {"type": "bind", "source": str(plugins), "target": "/var/lib/influxdb3/plugins"},
            {"type": "bind", "source": str(license_file), "target": "/test-license/license.jwt", "read_only": True},
        ]
        generated["volumes"] = {"test-data": {"external": True, "name": volume}}
        compose_file.write_text(json.dumps(generated))
        compose_file.chmod(0o600)
        command(["docker", "volume", "create", volume])
        command(["docker", "run", "--rm", "--user", "0", "--entrypoint", "chown",
                 "-v", f"{volume}:/data", image, service["user"], "/data"])
        started = True
        command(compose + ["up", "-d"], env=env)
        address = command(compose + ["port", SERVICE, "8181"], env=env).strip()
        url = "http://" + address
        env["TEST_PORT"] = address.rsplit(":", 1)[1]
        wait_ready(url, container)
        status, page = request(url + "/")
        require(status == 200 and b"<html" in page.lower(), "Embedded Explorer did not serve HTML")
        command(helper + ["bootstrap"], env=env)
        require((test_dir / "user-state").read_text().strip() == "created", "Installer did not create the admin")
        output = json.loads((test_dir / "user-output").read_text())
        require(output.get("username") == "admin", "Installer created an unexpected user")
        temporary_password = output.get("password")
        require(temporary_password, "Create-user output did not contain a temporary password")
        status, body = request(url + "/api/v3/authorize", body={"username": "admin", "password": temporary_password})
        require(status == 403 and b"password reset" in body.lower(), "First sign-in did not require a password reset")
        password = secrets.token_urlsafe(24)
        status, _ = request(url + "/api/v3/authorize/reset-password", body={
            "username": "admin", "password": temporary_password, "newPassword": password
        })
        require(status == 200, "Password reset failed")

        def login_and_check():
            status, body = request(url + "/api/v3/authorize", body={"username": "admin", "password": password})
            require(status == 200, "Sign-in failed")
            token = json.loads(body)["token"]
            status, body = request(url + "/api/v3/users", token=token)
            require(status == 200 and b'"admin"' in body, "Signed-in admin cannot list users")
            return token

        token = login_and_check()
        status, _ = request(url + "/api/v3/users")
        require(status in (401, 403), "User list permits unauthenticated access")
        status, _ = request(url + "/api/v3/authorize", body={"username": "admin", "password": temporary_password})
        require(status in (401, 403), "Old temporary password still works")
        print("PASS: real admin creation, forced reset, sign-in and access checks", flush=True)

        # Reuse the installer's saved key and session secret, then restart.
        command(helper + ["configure"], env=env)
        after = (test_dir / ".env").read_bytes()
        require(after.replace(b"EXPLORER_USER=admin\n", b"") == before, "Re-run changed the saved signing key or session secret")
        command(compose + ["restart"], env=env)
        # Docker can assign a different ephemeral host port after restart.
        address = command(compose + ["port", SERVICE, "8181"], env=env).strip()
        url = "http://" + address
        env["TEST_PORT"] = address.rsplit(":", 1)[1]
        wait_ready(url, container)
        status, _ = request(url + "/api/v3/users", token=token)
        require(status == 200, "Existing JWT stopped working after restart")
        login_and_check()
        command(helper + ["bootstrap"], env=env)
        require((test_dir / "user-state").read_text().strip() == "exists", "Re-run did not recognize the existing admin")
        require(not (test_dir / "user-output").read_text().strip(), "Re-run unexpectedly created a user")
        print("PASS: credentials, existing JWT and installer user record survive restart", flush=True)
    finally:
        if args.keep:
            print(f"Kept test files: {test_dir}\nContainer: {container}\nVolume: {volume}")
        else:
            if started:
                subprocess.run(compose + ["down", "--volumes"], env=env, capture_output=True, timeout=60)
            subprocess.run(["docker", "volume", "rm", volume], capture_output=True, timeout=30)
            shutil.rmtree(test_dir)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
        # Do not print subprocess output or request bodies; they hold credentials.
        raise SystemExit(f"FAIL: {error}") from None
