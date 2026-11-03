# Installer tests

Run the helper tests and shell checks:

```sh
env -u OS sh tests/test_install_functions.sh
shellcheck --severity=warning install_influxdb.sh tests/*.sh
```

The helper tests replace Docker, HTTP and key generators with command shims.
They cover OpenSSL and LibreSSL, host fallbacks, ssh-keygen and failure before startup.
They also cover the binary path's embedded UI helpers: the secret and key
files, the version gate, the readiness check and the displayed commands.
The loader refuses a function name that the script defines twice, because
the shell runs the last definition while the loader reads the first.

## Real Enterprise image

Install Docker with Compose, Python 3 and curl. Supply an existing Enterprise
license through `INFLUXDB3_LICENSE` (JWT content) or a file path:

```sh
INFLUXDB3_TEST_LICENSE_FILE=/path/to/license.jwt python3 tests/test_embedded_ui.py
```

The test pulls the installer's default Enterprise version. Use `--version 3.12.2`
to select a specific release. It fails if the license is missing or invalid.
It never requests a trial license.

The test calls the installer's Compose, key-generation and first-user helpers.
It starts the real image, checks Explorer HTML, verifies forced password reset,
signs in, and checks authenticated and unauthenticated access. It then checks
that the saved key, session secret, password, JWT and user record survive a restart.
Docker, user creation and authentication responses are not mocked.

The test changes only the generated deployment's resource names, port binding,
storage mounts, restart policy, CPU count and license source for isolation.
It binds a random loopback port and uses its own Docker data volume. This avoids
macOS bind-mount file-lock failures and leaves existing installations untouched.
The server command and authentication environment come from the installer.

By default, the test removes its container, volume and temporary files. Use
`--keep` to retain them for inspection. Retained files contain generated
credentials and the license; do not commit or upload them. The test prints
resource names but does not print credentials or server responses.

Run this integration test locally before merging authentication changes. It does
not run in GitHub Actions because the license stays outside Actions secrets.
CI runs the helper tests and shell checks without a license.
