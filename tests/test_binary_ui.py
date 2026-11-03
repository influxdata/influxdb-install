#!/usr/bin/env python3
"""Test the binary path's embedded UI against the real Enterprise release.

The installer's own gate (setup_embedded_ui, through tests/embedded_ui_helpers.sh)
creates the session secret and the JWT signing key with the host's openssl or
ssh-keygen and exports them, and the downloaded influxdb3 binary starts with
the flags the installer uses. The test then creates the operator token and
the first admin the way the installer's instructions say, and checks
password reset, sign-in, access, and that both secrets survive a restart.

Provide INFLUXDB3_LICENSE (JWT content) or INFLUXDB3_TEST_LICENSE_FILE.
The test never requests a license and prints no credentials. See tests/README.md.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import socket
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

from test_embedded_ui import REPO, command, request, require


RELEASES = "https://dl.influxdata.com/influxdb/releases"
UI_FLAGS = "--mode=all,webui --user-auth-type=basic --jwt-key-id=install-script"


def artifact():
    system, machine = platform.system(), platform.machine()
    if system == "Darwin" and machine == "arm64":
        return "darwin_arm64"
    if system == "Linux" and machine in ("x86_64", "amd64"):
        return "linux_amd64"
    if system == "Linux" and machine in ("aarch64", "arm64"):
        return "linux_arm64"
    raise RuntimeError(f"No Enterprise binary for {system} {machine}")


def download_binary(version, dest):
    """Download and verify the release tarball; return the binary inside it."""
    name = f"influxdb3-enterprise-{version}_{artifact()}.tar.gz"
    tarball = dest / name

    def fetch(url):
        # The release CDN refuses urllib's default User-Agent
        return urllib.request.urlopen(
            urllib.request.Request(url, headers={"User-Agent": "influxdb-install-tests"}), timeout=120
        )

    with fetch(f"{RELEASES}/{name}") as response, open(tarball, "wb") as out:
        shutil.copyfileobj(response, out)
    with fetch(f"{RELEASES}/{name}.sha256") as response:
        expected = response.read().decode().split()[0]
    require(hashlib.sha256(tarball.read_bytes()).hexdigest() == expected, "Tarball checksum mismatch")
    # The checksum comes from the same server as the archive, so it does not
    # protect against a hostile archive. Only the 'data' filter rejects
    # members that escape the extraction directory; never extract without it.
    require(hasattr(tarfile, "data_filter"),
            "This Python cannot extract archives safely (no tarfile.data_filter); "
            "use Python 3.12+ or a patched 3.8+, or pass --binary with an extracted binary")
    extract = dest / "extract"
    extract.mkdir()
    with tarfile.open(tarball) as tar:
        tar.extractall(extract, filter="data")
    tarball.unlink()
    return find_binary(extract)


def find_binary(root):
    # The binary must stay next to its bundled python/ directory.
    binaries = [p for p in Path(root).rglob("influxdb3") if p.is_file() and os.access(p, os.X_OK)]
    require(len(binaries) == 1, f"Expected one influxdb3 binary under {root}")
    return binaries[0]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Server:
    """The installer's gate plus the real binary, in one process."""

    def __init__(self, helper, env, log):
        self.helper, self.env, self.log = helper, env, log
        self.process = None

    def start(self):
        with open(self.log, "ab") as log:
            self.process = subprocess.Popen(self.helper + ["binary-serve"], env=self.env,
                                            stdout=log, stderr=subprocess.STDOUT)

    def wait_ready(self, url):
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            require(self.process.poll() is None, f"Server exited during startup (status {self.process.returncode})")
            try:
                status, page = request(url + "/")
                if status == 200 and b"<html" in page.lower():
                    return
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                pass
            time.sleep(1)
        raise RuntimeError("Server did not serve Explorer within 120 seconds")

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_version = re.search(
        r'^INFLUXDB_ENT_VERSION="?([0-9.]+)',
        (REPO / "install_influxdb.sh").read_text(), re.MULTILINE
    ).group(1)
    parser.add_argument("--version", default=default_version)
    parser.add_argument("--binary", help="An extracted influxdb3 binary to use instead of downloading")
    parser.add_argument("--keep", action="store_true", help="Keep the test files for inspection")
    args = parser.parse_args()
    require(re.fullmatch(r"3\.\d+\.\d+", args.version), "Use a final 3.Y.Z version")

    license_content = os.environ.get("INFLUXDB3_LICENSE", "")
    if not license_content:
        license_path = os.environ.get("INFLUXDB3_TEST_LICENSE_FILE")
        require(license_path, "Set INFLUXDB3_LICENSE or INFLUXDB3_TEST_LICENSE_FILE")
        license_content = Path(license_path).read_text()
    require(license_content.strip(), "The supplied license is empty")

    test_dir = Path(tempfile.mkdtemp(prefix="influxdb-install-binary-"))
    server = None
    try:
        if args.binary:
            binary = Path(args.binary).resolve()
            require(binary.is_file(), f"{binary} is not a file")
        else:
            print(f"Downloading InfluxDB 3 Enterprise {args.version} for {artifact()}", flush=True)
            binary = download_binary(args.version, test_dir)
        version_line = command([str(binary), "--version"])
        require(f" {args.version}," in version_line or f" {args.version}" in version_line,
                "The binary does not report the requested version")
        print(f"Testing {binary}", flush=True)

        license_file = test_dir / "license.jwt"
        license_file.write_text(license_content)
        license_file.chmod(0o600)
        port = free_port()
        url = f"http://127.0.0.1:{port}"
        env = dict(os.environ)
        env.pop("INFLUXDB3_LICENSE", None)
        env.pop("INFLUXDB3_WEBUI_SESSION_SECRET", None)
        env.pop("INFLUXDB3_JWT_PRIVATE_KEY", None)
        env.update(TEST_REPO=str(REPO), TEST_DIR=str(test_dir), TEST_VERSION=args.version,
                   TEST_BINARY=str(binary), TEST_PORT=str(port), INFLUXDB3_NUM_CORES="2")
        helper = ["sh", str(REPO / "tests/embedded_ui_helpers.sh")]
        server = Server(helper, env, test_dir / "server.log")

        server.start()
        server.wait_ready(url)
        secret_file = test_dir / "webui-session-secret"
        key_file = test_dir / "jwt-private-key.pem"
        require((test_dir / "ui-flags").read_text().strip() == UI_FLAGS, "The gate did not set the UI flags")
        require(re.fullmatch(r"[0-9a-f]{64}\n", secret_file.read_text()), "The gate did not write a session secret")
        key = key_file.read_text()
        require(key.startswith("-----BEGIN RSA PRIVATE KEY-----") and "-----END RSA PRIVATE KEY-----" in key,
                "The gate did not write a PKCS#1 signing key")
        for path in (secret_file, key_file):
            require(path.stat().st_mode & 0o777 == 0o600, f"{path.name} is not mode 600")
        secrets_before = secret_file.read_bytes() + key_file.read_bytes()
        print("PASS: the installer's gate created both secrets with the host generator", flush=True)

        # The first admin, as the installer's first-user note says: the
        # operator token comes from the server, the user from the CLI.
        status, body = request(url + "/api/v3/configure/token/admin", body={})
        require(status == 201, "Operator token creation failed")
        token = json.loads(body)["token"]
        env_cli = dict(env, INFLUXDB3_AUTH_TOKEN=token)
        output = json.loads(command([str(binary), "create", "user", "--host", url, "--username", "admin",
                                     "--role", "Admin", "--require-password-reset"], env=env_cli))
        require(output.get("username") == "admin", "The CLI created an unexpected user")
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
            jwt = json.loads(body)["token"]
            status, body = request(url + "/api/v3/users", token=jwt)
            require(status == 200 and b'"admin"' in body, "Signed-in admin cannot list users")
            return jwt

        jwt = login_and_check()
        status, _ = request(url + "/api/v3/users")
        require(status in (401, 403), "User list permits unauthenticated access")
        status, _ = request(url + "/api/v3/authorize", body={"username": "admin", "password": temporary_password})
        require(status in (401, 403), "Old temporary password still works")
        print("PASS: operator token, admin creation, forced reset, sign-in and access checks", flush=True)

        # A re-run: the gate reuses both files, and the server restarts on them.
        server.stop()
        server.start()
        server.wait_ready(url)
        require(secret_file.read_bytes() + key_file.read_bytes() == secrets_before,
                "Re-run changed the saved signing key or session secret")
        status, _ = request(url + "/api/v3/users", token=jwt)
        require(status == 200, "Existing JWT stopped working after restart")
        login_and_check()
        print("PASS: both secrets and the existing JWT survive a restart", flush=True)
    finally:
        if server:
            server.stop()
        if args.keep:
            print(f"Kept test files: {test_dir}")
        else:
            shutil.rmtree(test_dir, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
        # Do not print subprocess output or request bodies; they hold credentials.
        raise SystemExit(f"FAIL: {error}") from None
