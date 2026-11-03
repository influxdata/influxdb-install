#!/bin/sh
# shellcheck disable=SC2034  # globals set here are read by the loaded functions
# Unit tests for the helper functions in install_influxdb.sh.
#
# The script runs its installation flow at load time, so the tests do not
# source it. Instead each test loads one function's definition from the file:
# the lines from "name() {" at column 0 to the next "}" at column 0 that is
# not inside a here-document.
#
# The commands those functions call (curl, docker, open, xdg-open) are
# replaced by shims in a scratch directory for the first-user tests, so no
# server and no Docker daemon is needed. The compose check alone runs the
# real "docker compose config" when Docker is present, and is skipped
# otherwise.
#
# Run: sh tests/test_install_functions.sh
# Exit status is 1 when a check fails. Needs only POSIX sh, awk, sed, grep, od.
set -u

# Byte-wise character ranges in the case patterns below
LC_ALL=C
export LC_ALL

# Docker reads its config and compose plugin from $HOME/.docker; keep the
# real one while the tests point HOME at a scratch directory
DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
export DOCKER_CONFIG
REAL_DOCKER=$(command -v docker 2>/dev/null) || REAL_DOCKER=""
ORIG_PATH="$PATH"

SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/install_influxdb.sh
PASSED=0
FAILED=0

# shellcheck source=tests/load_install_function.sh
. "$(dirname "$SCRIPT")/tests/load_install_function.sh"

pass() {
    PASSED=$((PASSED + 1))
}

fail() {
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

# check_status DESCRIPTION EXPECTED_STATUS COMMAND...
check_status() {
    DESC="$1"
    WANT="$2"
    shift 2
    if "$@" >/dev/null 2>&1; then GOT=0; else GOT=$?; fi
    if [ "$GOT" -eq "$WANT" ]; then pass; else fail "$DESC: expected status $WANT, got $GOT"; fi
}

# check_equal DESCRIPTION EXPECTED ACTUAL
check_equal() {
    if [ "$2" = "$3" ]; then pass; else fail "$1: expected '$2', got '$3'"; fi
}

# check_file_has DESCRIPTION FILE FIXED_STRING
check_file_has() {
    if grep -qF -- "$3" "$2"; then pass; else fail "$1: '$3' missing from $2"; fi
}

# check_file_lacks DESCRIPTION FILE FIXED_STRING
check_file_lacks() {
    if grep -qF -- "$3" "$2"; then fail "$1: '$3' present in $2"; else pass; fi
}

# Constants and colour variables the functions use; empty colours keep the
# output plain
BOLD=""; DIM=""; BLUE=""; NC=""; YELLOW=""; BOLDGREEN=""; RED=""
MANUAL_TOKEN_MSG="MANUAL_TOKEN_CREATION_REQUIRED"
FIRST_EXPLORER_USER="admin"
# generate_session_secret picks shasum or sha256sum from OS, as the script does
case "$(uname -s)" in
    Darwin*) OS="Darwin" ;;
    *)       OS="Linux" ;;
esac

load_function version_at_least
load_function has_embedded_ui
load_function is_session_secret
load_function generate_session_secret
load_function is_jwt_private_key
load_function create_docker_directories
load_function generate_docker_compose_yaml
load_function write_env_file
load_function read_env_value
load_function read_env_jwt_private_key
load_function load_session_secret
load_function load_jwt_private_key
load_function extract_token_from_explorer_config
load_function create_operator_token
load_function print_operator_token_box
load_function setup_first_explorer_user
load_function display_first_user_steps
load_function finish_embedded_ui_setup
load_function open_browser_url

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

# Placeholder fixtures: the key check reads only the BEGIN and END lines,
# and the token is never sent anywhere
PKCS1="-----BEGIN RSA PRIVATE KEY-----
placeholder-line-1
placeholder-line-2
-----END RSA PRIVATE KEY-----"
PKCS8="-----BEGIN PRIVATE KEY-----
placeholder
-----END PRIVATE KEY-----"
TOKEN_FIXTURE="apiv3_redacted"
HEX64=$(printf '%064d' 0)

# --- version_at_least ---
check_status "3.11.9 is below 3.12.0" 1 version_at_least 3.11.9 3.12.0
check_status "3.12.0 is at least 3.12.0" 0 version_at_least 3.12.0 3.12.0
check_status "3.12.1 is at least 3.12.0" 0 version_at_least 3.12.1 3.12.0
check_status "4.0.0 is at least 3.12.0" 0 version_at_least 4.0.0 3.12.0
check_status "3.9.13 is below 3.12.0" 1 version_at_least 3.9.13 3.12.0
check_status "a bare major version 3 is below 3.12.0" 1 version_at_least 3 3.12.0
check_status "3.12 is at least 3.12.0" 0 version_at_least 3.12 3.12.0

# --- has_embedded_ui ---
EDITION="Core"; INFLUXDB_VERSION="3.12.1"
check_status "Core 3.12.1 has no embedded UI" 1 has_embedded_ui
EDITION="Enterprise"; INFLUXDB_VERSION="3.11.7"
check_status "Enterprise 3.11.7 has no embedded UI" 1 has_embedded_ui
EDITION="Enterprise"; INFLUXDB_VERSION="3.12.0"
check_status "Enterprise 3.12.0 has the embedded UI" 0 has_embedded_ui
EDITION="Enterprise"; INFLUXDB_VERSION="3.12.1"
check_status "Enterprise 3.12.1 has the embedded UI" 0 has_embedded_ui

# --- is_session_secret ---
check_status "63 characters rejected" 1 is_session_secret "$(printf '%063d' 0)"
check_status "64 hex characters accepted" 0 is_session_secret "$HEX64"
check_status "65 characters rejected" 1 is_session_secret "$(printf '%065d' 0)"
check_status "64 characters with a non-hex character rejected" 1 is_session_secret "$(printf '%063d' 0)g"
check_status "empty secret rejected" 1 is_session_secret ""
check_status "an older sha256-style secret is accepted" 0 is_session_secret "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
check_status "upper-case hex is accepted" 0 is_session_secret "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"

# --- generate_session_secret ---
SECRET1=$(generate_session_secret)
SECRET2=$(generate_session_secret)
check_equal "generated secret is 64 characters" 64 "${#SECRET1}"
check_status "generated secret is hex" 0 is_session_secret "$SECRET1"
case "$SECRET1" in
    *[ABCDEF]*) fail "generated secret has upper-case hex" ;;
    *) pass ;;
esac
if [ "$SECRET1" != "$SECRET2" ]; then pass; else fail "two generated secrets are equal"; fi

# --- is_jwt_private_key ---
check_status "PKCS#1 key accepted" 0 is_jwt_private_key "$PKCS1"
check_status "PKCS#8 key rejected" 1 is_jwt_private_key "$PKCS8"
check_status "empty key rejected" 1 is_jwt_private_key ""
check_status "truncated PKCS#1 key rejected" 1 is_jwt_private_key "-----BEGIN RSA PRIVATE KEY-----
abc"

# --- write_env_file and the readers ---
ENV_DIR="$TMP/env"
mkdir -p "$ENV_DIR"
SECRET="$HEX64"
check_status "write_env_file with a key and a user succeeds" 0 write_env_file enterprise "$SECRET" "user@example.com" "$ENV_DIR" trial "$PKCS1" admin
check_equal ".env mode is 600" "-rw-------" "$(ls -l "$ENV_DIR/.env" | cut -c1-10)"
check_equal "SESSION_SECRET reads back with the PEM present" "$SECRET" "$(read_env_value "$ENV_DIR/.env" SESSION_SECRET)"
check_equal "INFLUXDB_EMAIL reads back with the PEM present" "user@example.com" "$(read_env_value "$ENV_DIR/.env" INFLUXDB_EMAIL)"
check_equal "INFLUXDB_LICENSE_TYPE reads back with the PEM present" "trial" "$(read_env_value "$ENV_DIR/.env" INFLUXDB_LICENSE_TYPE)"
check_equal "EXPLORER_USER reads back with the PEM present" "admin" "$(read_env_value "$ENV_DIR/.env" EXPLORER_USER)"
check_equal "JWT_PRIVATE_KEY round-trips byte for byte" "$PKCS1" "$(read_env_jwt_private_key "$ENV_DIR/.env")"
check_status "the read-back key is still a PKCS#1 key" 0 is_jwt_private_key "$(read_env_jwt_private_key "$ENV_DIR/.env")"
LAST_ENTRY_LINE=$(grep -n '^[A-Z_]*=' "$ENV_DIR/.env" | tail -n1 | cut -d: -f1)
JWT_ENTRY_LINE=$(grep -n '^JWT_PRIVATE_KEY=' "$ENV_DIR/.env" | cut -d: -f1)
check_equal "JWT_PRIVATE_KEY is the last entry" "$JWT_ENTRY_LINE" "$LAST_ENTRY_LINE"
USER_ENTRY_LINE=$(grep -n '^EXPLORER_USER=' "$ENV_DIR/.env" | cut -d: -f1)
if [ "$USER_ENTRY_LINE" -lt "$JWT_ENTRY_LINE" ]; then pass; else fail "EXPLORER_USER must come before the multi-line key"; fi

check_status "write_env_file without a key or user succeeds" 0 write_env_file enterprise "$SECRET" "user@example.com" "$ENV_DIR" trial "" ""
check_file_lacks "no JWT_PRIVATE_KEY line without a key" "$ENV_DIR/.env" "JWT_PRIVATE_KEY"
check_file_lacks "no EXPLORER_USER line without a user" "$ENV_DIR/.env" "EXPLORER_USER"
check_status "read_env_jwt_private_key fails without a key" 1 read_env_jwt_private_key "$ENV_DIR/.env"
check_status "read_env_jwt_private_key fails without a file" 1 read_env_jwt_private_key "$ENV_DIR/missing"

check_status "write_env_file for Core keeps a stored key and user" 0 write_env_file core "$SECRET" "" "$ENV_DIR" "" "$PKCS1" admin
check_file_lacks "Core .env has no INFLUXDB_EMAIL" "$ENV_DIR/.env" "INFLUXDB_EMAIL"
check_file_lacks "Core .env has no INFLUXDB_LICENSE_TYPE" "$ENV_DIR/.env" "INFLUXDB_LICENSE_TYPE"
check_equal "Core .env keeps the JWT key" "$PKCS1" "$(read_env_jwt_private_key "$ENV_DIR/.env")"
check_equal "Core .env keeps the Explorer user" "admin" "$(read_env_value "$ENV_DIR/.env" EXPLORER_USER)"

# --- load_session_secret (the reuse path of a re-run) ---
REUSE_DIR="$TMP/reuse"
mkdir -p "$REUSE_DIR"
OLD_SECRET="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
write_env_file core "$OLD_SECRET" "" "$REUSE_DIR" "" "" ""
SESSION_SECRET=""
load_session_secret "$REUSE_DIR/.env" > "$TMP/out"
check_equal "a stored sha256-style secret is kept" "$OLD_SECRET" "$SESSION_SECRET"
check_equal "keeping a secret prints no warning" "" "$(cat "$TMP/out")"

printf 'SESSION_SECRET=not-a-secret\n' > "$REUSE_DIR/.env"
SESSION_SECRET=""
load_session_secret "$REUSE_DIR/.env" > "$TMP/out"
check_file_has "a malformed stored secret warns" "$TMP/out" "Warning: SESSION_SECRET in $REUSE_DIR/.env is not a usable session secret; generating a new one"
check_status "a malformed stored secret is replaced by a valid one" 0 is_session_secret "$SESSION_SECRET"
if [ "$SESSION_SECRET" != "not-a-secret" ]; then pass; else fail "malformed secret was kept"; fi

SESSION_SECRET=""
load_session_secret "$REUSE_DIR/missing" > "$TMP/out"
check_status "no .env gives a new valid secret" 0 is_session_secret "$SESSION_SECRET"
check_equal "no .env prints no warning" "" "$(cat "$TMP/out")"

# --- load_jwt_private_key (every edition keeps the key) ---
write_env_file enterprise "$HEX64" "user@example.com" "$REUSE_DIR" trial "$PKCS1" ""
JWT_PRIVATE_KEY=""
load_jwt_private_key "$REUSE_DIR/.env" false > "$TMP/out"
check_equal "a Core or pre-3.12 run keeps the stored key" "$PKCS1" "$JWT_PRIVATE_KEY"
check_equal "keeping the key prints no warning" "" "$(cat "$TMP/out")"
JWT_PRIVATE_KEY=""
load_jwt_private_key "$REUSE_DIR/.env" true > "$TMP/out"
check_equal "an embedded-UI run keeps the stored key" "$PKCS1" "$JWT_PRIVATE_KEY"

write_env_file enterprise "$HEX64" "user@example.com" "$REUSE_DIR" trial "$PKCS8" ""
JWT_PRIVATE_KEY="stale"
load_jwt_private_key "$REUSE_DIR/.env" false > "$TMP/out"
check_equal "a malformed key is dropped on a run that does not use it" "" "$JWT_PRIVATE_KEY"
check_file_has "dropping a malformed key warns with 'discarding it'" "$TMP/out" "Warning: JWT_PRIVATE_KEY in $REUSE_DIR/.env is not a PKCS#1 RSA key; discarding it"
JWT_PRIVATE_KEY="stale"
load_jwt_private_key "$REUSE_DIR/.env" true > "$TMP/out"
check_equal "a malformed key is dropped on an embedded-UI run" "" "$JWT_PRIVATE_KEY"
check_file_has "dropping a malformed key on an embedded-UI run warns about sign-ins" "$TMP/out" "generating a new one. Users will need to sign in again."

JWT_PRIVATE_KEY="stale"
load_jwt_private_key "$REUSE_DIR/missing" true > "$TMP/out"
check_equal "no .env gives an empty key" "" "$JWT_PRIVATE_KEY"
check_equal "no .env prints no key warning" "" "$(cat "$TMP/out")"

# Helper check only: the key and the record pass through the loaders and
# write_env_file; the production sequence is run under "setup_docker_compose
# end to end" below
write_env_file enterprise "$HEX64" "user@example.com" "$REUSE_DIR" trial "$PKCS1" admin
load_jwt_private_key "$REUSE_DIR/.env" false
EXPLORER_USER=$(read_env_value "$REUSE_DIR/.env" EXPLORER_USER) || EXPLORER_USER=""
write_env_file core "$HEX64" "" "$REUSE_DIR" "" "$JWT_PRIVATE_KEY" "$EXPLORER_USER"
JWT_PRIVATE_KEY=""
load_jwt_private_key "$REUSE_DIR/.env" true
check_equal "the key survives a Core run in between" "$PKCS1" "$JWT_PRIVATE_KEY"
check_equal "the Explorer user survives a Core run in between" "admin" "$(read_env_value "$REUSE_DIR/.env" EXPLORER_USER)"

# --- generate_docker_compose_yaml ---
HOME="$TMP/home"
export HOME
DOCKER_IMAGE="influxdb:3.12.1-enterprise"
EXPLORER_IMAGE="influxdata/influxdb3-ui"
INFLUXDB_PORT=8181
EXPLORER_PORT=8888
INFLUXDB_VERSION="3.12.1"
COMPOSE_DIR="$TMP/compose-embedded"
mkdir -p "$COMPOSE_DIR"
generate_docker_compose_yaml enterprise "$COMPOSE_DIR" trial true
COMPOSE="$COMPOSE_DIR/docker-compose.yml"
check_file_has "embedded: --mode=all,webui" "$COMPOSE" "- --mode=all,webui"
check_file_has "embedded: --user-auth-type=basic" "$COMPOSE" "- --user-auth-type=basic"
check_file_has "embedded: --jwt-key-id" "$COMPOSE" "- --jwt-key-id=install-script"
check_file_has "embedded: --cluster-id kept" "$COMPOSE" "- --cluster-id=cluster0"
check_file_has "embedded: session secret from the environment" "$COMPOSE" 'INFLUXDB3_WEBUI_SESSION_SECRET=${SESSION_SECRET}'
check_file_has "embedded: JWT key from the environment" "$COMPOSE" 'INFLUXDB3_JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY}'
check_file_has "embedded: license email from the environment" "$COMPOSE" 'INFLUXDB3_LICENSE_EMAIL=${INFLUXDB_EMAIL}'
check_file_has "embedded: InfluxDB port published as at base" "$COMPOSE" '- "8181:8181"'
check_file_lacks "embedded: no loopback-only publish" "$COMPOSE" "127.0.0.1"
check_file_lacks "embedded: no Explorer service" "$COMPOSE" "influxdb3-explorer"
check_file_lacks "embedded: no Explorer session secret" "$COMPOSE" "SESSION_SECRET_KEY"
check_file_lacks "embedded: secret not on the command line" "$COMPOSE" "webui-session-secret"
check_file_lacks "embedded: key not on the command line" "$COMPOSE" "jwt-private-key"

COMPOSE_DIR="$TMP/compose-explorer"
mkdir -p "$COMPOSE_DIR"
generate_docker_compose_yaml enterprise "$COMPOSE_DIR" trial false
COMPOSE="$COMPOSE_DIR/docker-compose.yml"
check_file_has "explorer: Explorer service present" "$COMPOSE" "influxdb3-explorer:"
check_file_has "explorer: Explorer image" "$COMPOSE" "image: influxdata/influxdb3-ui"
check_file_has "explorer: Explorer port" "$COMPOSE" '"8888:8080"'
check_file_has "explorer: Explorer session secret" "$COMPOSE" 'SESSION_SECRET_KEY=${SESSION_SECRET}'
check_file_has "explorer: InfluxDB port published on all interfaces" "$COMPOSE" '- "8181:8181"'
check_file_lacks "explorer: no webui mode" "$COMPOSE" "webui"
check_file_lacks "explorer: no user auth" "$COMPOSE" "user-auth-type"
check_file_lacks "explorer: no JWT key" "$COMPOSE" "JWT_PRIVATE_KEY"

COMPOSE_DIR="$TMP/compose-core"
mkdir -p "$COMPOSE_DIR"
DOCKER_IMAGE="influxdb:3.12.1-core"
generate_docker_compose_yaml core "$COMPOSE_DIR" "" false
COMPOSE="$COMPOSE_DIR/docker-compose.yml"
check_file_has "core: Explorer service present" "$COMPOSE" "influxdb3-explorer:"
check_file_has "core: depends on the core service" "$COMPOSE" "- influxdb3-core"
check_file_lacks "core: no cluster id" "$COMPOSE" "cluster-id"
check_file_lacks "core: no license environment" "$COMPOSE" "INFLUXDB3_LICENSE"
check_file_lacks "core: no webui mode" "$COMPOSE" "webui"

# Compose must parse the multi-line double-quoted key in .env; skipped without Docker
if [ -n "$REAL_DOCKER" ] && "$REAL_DOCKER" compose version >/dev/null 2>&1; then
    COMPOSE_DIR="$TMP/compose-embedded"
    write_env_file enterprise "$SECRET" "user@example.com" "$COMPOSE_DIR" trial "$PKCS1" admin
    RENDERED=$(cd "$COMPOSE_DIR" && "$REAL_DOCKER" compose config 2>&1)
    check_status "docker compose config parses the generated files" 0 sh -c 'cd "$1" && "$2" compose config >/dev/null 2>&1' sh "$COMPOSE_DIR" "$REAL_DOCKER"
    case "$RENDERED" in
        *"-----END RSA PRIVATE KEY-----"*) pass ;;
        *) fail "docker compose config did not render the multi-line JWT key" ;;
    esac
else
    printf 'skip: docker compose not available; the .env parse check did not run\n'
fi

# --- create_docker_directories ---
HOME="$TMP/home-embedded"
create_docker_directories "$HOME/.influxdb/docker" true
if [ -d "$HOME/.influxdb/docker" ] && [ -d "$HOME/.influxdb/data" ] && [ -d "$HOME/.influxdb/plugins" ]; then pass; else fail "embedded: docker, data and plugins directories created"; fi
if [ -e "$HOME/.influxdb/docker/explorer" ]; then fail "embedded: explorer/ must not be created"; else pass; fi

HOME="$TMP/home-explorer"
create_docker_directories "$HOME/.influxdb/docker" false
if [ -d "$HOME/.influxdb/docker/explorer/db" ] && [ -d "$HOME/.influxdb/docker/explorer/config" ]; then pass; else fail "explorer: explorer/db and explorer/config created"; fi

HOME="$TMP/home-default"
create_docker_directories "$HOME/.influxdb/docker"
if [ -d "$HOME/.influxdb/docker/explorer/db" ]; then pass; else fail "default: explorer/db created when \$2 is omitted"; fi

# --- extract_token_from_explorer_config ---
CFG_HOME="$TMP/cfg"
mkdir -p "$CFG_HOME/explorer/config"
printf '{\n  "DEFAULT_INFLUX_SERVER": "http://influxdb3-enterprise:8181",\n  "DEFAULT_API_TOKEN": "YOUR_TOKEN_HERE"\n}\n' > "$CFG_HOME/explorer/config/config.json"
check_status "placeholder token is rejected" 1 extract_token_from_explorer_config "$CFG_HOME"
check_equal "placeholder token prints nothing" "" "$(extract_token_from_explorer_config "$CFG_HOME")"
printf '{\n  "DEFAULT_API_TOKEN": "null"\n}\n' > "$CFG_HOME/explorer/config/config.json"
check_status "null token is rejected" 1 extract_token_from_explorer_config "$CFG_HOME"
printf '{\n  "DEFAULT_API_TOKEN": "%s"\n}\n' "$TOKEN_FIXTURE" > "$CFG_HOME/explorer/config/config.json"
check_status "a real token is accepted" 0 extract_token_from_explorer_config "$CFG_HOME"
check_equal "a real token is printed" "$TOKEN_FIXTURE" "$(extract_token_from_explorer_config "$CFG_HOME")"
check_status "a missing config fails" 1 extract_token_from_explorer_config "$TMP/nowhere"

# --- Shims for curl, docker and the browser opener ---
SHIM_BIN="$TMP/bin"
mkdir -p "$SHIM_BIN"
SHIM_LOG="$TMP/shim.log"
export SHIM_LOG
cat > "$SHIM_BIN/curl" <<'STUB'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$SHIM_LOG"
case "$*" in
    *configure/token/admin*)
        case "${SHIM_TOKEN:-new}" in
            new) printf '{"token":"%s"}\n201\n' "$SHIM_NEW_TOKEN" ;;
            conflict) printf '{"error":"operator token already configured"}\n409\n' ;;
            *) printf 'unavailable\n503\n' ;;
        esac
        ;;
    *)
        [ "${SHIM_SMOKE:-ok}" = ok ]
        ;;
esac
STUB
cat > "$SHIM_BIN/docker" <<'STUB'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$SHIM_LOG"
printf 'env INFLUXDB3_AUTH_TOKEN=%s\n' "${INFLUXDB3_AUTH_TOKEN:-unset}" >> "$SHIM_LOG"
case "$*" in
    *"create user"*)
        case "${SHIM_CREATE:-ok}" in
            ok) printf '{ "userId": 0, "username": "admin", "password": "password" }\n'; exit 0 ;;
            exists) printf 'Create command failed: username already exists: admin\n' >&2; exit 1 ;;
            other-exists) printf 'Create command failed: role admin already exists\n' >&2; exit 1 ;;
            *) printf 'Create command failed: unauthorized\n' >&2; exit 1 ;;
        esac
        ;;
    "info"|"compose version"|"manifest inspect "*|"compose down"*|"compose pull "*|"compose up "*|"inspect "*)
        exit 0
        ;;
    "logs "*)
        printf 'startup time: 1s\n'
        exit 0
        ;;
    "ps")
        printf 'id  image  running  influxdb3-enterprise\n'
        exit 0
        ;;
    *"--entrypoint openssl "*)
        # openssl3: -traditional yields PKCS#1 at once, the plain form PKCS#8
        # libressl: rejects -traditional, the plain form yields PKCS#1
        case "${SHIM_IMAGE_KEY:-openssl3}" in
            openssl3)
                case "$*" in
                    *"genrsa -traditional 4096") printf '%s\n' "$SHIM_PKCS1" ;;
                    *) printf '%s\n' "$SHIM_PKCS8" ;;
                esac
                exit 0
                ;;
            libressl)
                case "$*" in
                    *"genrsa 4096") printf '%s\n' "$SHIM_PKCS1"; exit 0 ;;
                    *) exit 1 ;;
                esac
                ;;
            *) exit 1 ;;
        esac
        ;;
esac
exit 1
STUB
cat > "$SHIM_BIN/open" <<'STUB'
#!/bin/sh
printf 'open %s\n' "$*" >> "$SHIM_LOG"
STUB
chmod +x "$SHIM_BIN/curl" "$SHIM_BIN/docker" "$SHIM_BIN/open"
cp "$SHIM_BIN/open" "$SHIM_BIN/xdg-open"
PATH="$SHIM_BIN:$ORIG_PATH"
export PATH
SHIM_NEW_TOKEN="$TOKEN_FIXTURE"
SHIM_PKCS1="$PKCS1"
export SHIM_NEW_TOKEN SHIM_PKCS1 SHIM_TOKEN SHIM_SMOKE SHIM_CREATE

reset_shims() {
    # open_browser_url starts the opener in the background; let it finish
    # before the log is truncated or read
    wait
    : > "$SHIM_LOG"
    SHIM_TOKEN="${1:-new}"
    SHIM_CREATE="${2:-ok}"
    SHIM_SMOKE="${3:-ok}"
}

CONTAINER="influxdb3-enterprise"
INFLUXDB_PORT=8181
FU_DIR="$TMP/first-user"
mkdir -p "$FU_DIR"

# --- setup_first_explorer_user ---
# Fresh server: a new token, then the user
reset_shims new ok
setup_first_explorer_user "$CONTAINER" "$FU_DIR" "" > "$TMP/out"; RC=$?
check_equal "fresh: state is created" created "$FIRST_USER_STATE"
check_equal "fresh: returns 0" 0 "$RC"
check_file_has "fresh: the new token is shown once" "$TMP/out" "OPERATOR TOKEN: Save this token. It will not be shown again."
check_file_has "fresh: the token value is in the box" "$TMP/out" "$TOKEN_FIXTURE"
check_file_has "fresh: the token reaches the CLI through the environment" "$SHIM_LOG" "env INFLUXDB3_AUTH_TOKEN=$TOKEN_FIXTURE"
check_file_has "fresh: create user runs inside the container with the expected flags" "$SHIM_LOG" "docker exec -e INFLUXDB3_AUTH_TOKEN $CONTAINER influxdb3 create user --username admin --role Admin --require-password-reset"
if grep '^docker ' "$SHIM_LOG" | grep -qF "$TOKEN_FIXTURE"; then fail "fresh: the token must not be on the docker command line"; else pass; fi
case "$FIRST_USER_OUTPUT" in
    *'"username": "admin", "password": "password"'*) pass ;;
    *) fail "fresh: FIRST_USER_OUTPUT must hold the CLI output" ;;
esac

# Re-run after the script created the user: the token exists, .env records the user
reset_shims conflict ok
setup_first_explorer_user "$CONTAINER" "$FU_DIR" admin > "$TMP/out"; RC=$?
check_equal "recorded user: state is exists" exists "$FIRST_USER_STATE"
check_equal "recorded user: returns 0" 0 "$RC"
check_file_lacks "recorded user: no create user call" "$SHIM_LOG" "create user"
check_file_lacks "recorded user: no token box" "$TMP/out" "OPERATOR TOKEN"

# Upgrade from the old Explorer layout: the token exists and config.json holds it
mkdir -p "$FU_DIR/explorer/config"
printf '{\n  "DEFAULT_API_TOKEN": "%s"\n}\n' "$TOKEN_FIXTURE" > "$FU_DIR/explorer/config/config.json"
reset_shims conflict ok
setup_first_explorer_user "$CONTAINER" "$FU_DIR" "" > "$TMP/out"; RC=$?
check_equal "old layout: state is created" created "$FIRST_USER_STATE"
# The token API answered 409, so the only token the CLI can have is the stored one
check_file_has "old layout: the stored token is used" "$SHIM_LOG" "env INFLUXDB3_AUTH_TOKEN=$TOKEN_FIXTURE"
check_file_lacks "old layout: no token box for a reused token" "$TMP/out" "OPERATOR TOKEN"

# Upgrade where the user already exists but .env does not record it
reset_shims conflict exists
setup_first_explorer_user "$CONTAINER" "$FU_DIR" "" > "$TMP/out"; RC=$?
check_equal "user exists: state is exists" exists "$FIRST_USER_STATE"
check_equal "user exists: returns 0" 0 "$RC"

# Upgrade from an install whose token this script does not know
rm -rf "$FU_DIR/explorer"
reset_shims conflict ok
setup_first_explorer_user "$CONTAINER" "$FU_DIR" "" > "$TMP/out"; RC=$?
check_equal "unknown token: state is manual" manual "$FIRST_USER_STATE"
check_equal "unknown token: returns 1" 1 "$RC"
check_file_lacks "unknown token: no create user call" "$SHIM_LOG" "create user"

# A placeholder token in config.json counts as unknown
mkdir -p "$FU_DIR/explorer/config"
printf '{\n  "DEFAULT_API_TOKEN": "YOUR_TOKEN_HERE"\n}\n' > "$FU_DIR/explorer/config/config.json"
reset_shims conflict ok
setup_first_explorer_user "$CONTAINER" "$FU_DIR" "" > "$TMP/out"; RC=$?
check_equal "placeholder token: state is manual" manual "$FIRST_USER_STATE"
rm -rf "$FU_DIR/explorer"

# The CLI fails for another reason
reset_shims new fail
setup_first_explorer_user "$CONTAINER" "$FU_DIR" "" > "$TMP/out"; RC=$?
check_equal "cli failure: state is failed" failed "$FIRST_USER_STATE"
check_equal "cli failure: returns 1" 1 "$RC"
case "$FIRST_USER_OUTPUT" in
    *unauthorized*) pass ;;
    *) fail "cli failure: FIRST_USER_OUTPUT must hold the CLI error" ;;
esac

# An "already exists" error about something other than the username is a failure
reset_shims new other-exists
setup_first_explorer_user "$CONTAINER" "$FU_DIR" "" > "$TMP/out"; RC=$?
check_equal "other already-exists error: state is failed" failed "$FIRST_USER_STATE"
check_equal "other already-exists error: returns 1" 1 "$RC"

# The token API does not answer (create_operator_token retries with two 2 s sleeps)
reset_shims fail ok
setup_first_explorer_user "$CONTAINER" "$FU_DIR" "" > "$TMP/out"; RC=$?
check_equal "no token: state is no_token" no_token "$FIRST_USER_STATE"
check_equal "no token: returns 1" 1 "$RC"
check_file_lacks "no token: no create user call" "$SHIM_LOG" "create user"

# --- finish_embedded_ui_setup ---
EDITION_NAME="Enterprise"
EDITION_TYPE="enterprise"
SESSION_SECRET="$HEX64"
LICENSE_EMAIL="user@example.com"
LICENSE_TYPE="trial"
JWT_PRIVATE_KEY="$PKCS1"
HOME="$TMP/home-finish"
FIN_DIR="$TMP/finish"
mkdir -p "$FIN_DIR"

# Fresh install: user created, browser opened, user recorded
EXPLORER_USER=""
reset_shims new ok ok
finish_embedded_ui_setup "$CONTAINER" "$FIN_DIR" > "$TMP/out"
wait
check_file_has "finish fresh: smoke check succeeds" "$TMP/out" "Checking InfluxDB 3 Explorer...SUCCESS"
check_file_has "finish fresh: sign-in box" "$TMP/out" "EXPLORER SIGN-IN: Save the temporary password. It will not be shown again."
check_file_has "finish fresh: CLI output shown" "$TMP/out" '"username": "admin", "password": "password"'
check_file_has "finish fresh: deployed with Explorer" "$TMP/out" "InfluxDB 3 Enterprise with InfluxDB 3 Explorer successfully deployed"
check_file_has "finish fresh: sign-in hint" "$TMP/out" "sign in as admin; the UI asks for a new password"
check_file_has "finish fresh: browser opened" "$SHIM_LOG" "open http://localhost:8181"
check_equal "finish fresh: user recorded in .env" "admin" "$(read_env_value "$FIN_DIR/.env" EXPLORER_USER)"
check_equal "finish fresh: key kept in .env" "$PKCS1" "$(read_env_jwt_private_key "$FIN_DIR/.env")"
check_equal "finish fresh: EXPLORER_USER set for the caller" admin "$EXPLORER_USER"
check_file_lacks "finish fresh: no manual steps" "$TMP/out" "Create the first Explorer user before you sign in"

# Re-run: token exists, user recorded; nothing to create
EXPLORER_USER="admin"
reset_shims conflict ok ok
finish_embedded_ui_setup "$CONTAINER" "$FIN_DIR" > "$TMP/out"
wait
check_file_has "finish re-run: open UI line" "$TMP/out" "Open Explorer UI: http://localhost:8181"
check_file_has "finish re-run: browser opened" "$SHIM_LOG" "open http://localhost:8181"
check_file_lacks "finish re-run: no create user call" "$SHIM_LOG" "create user"
check_file_lacks "finish re-run: no sign-in box" "$TMP/out" "EXPLORER SIGN-IN"

# Upgrade with an unknown token: steps shown, browser not opened, nothing recorded
EXPLORER_USER=""
rm -f "$FIN_DIR/.env"
reset_shims conflict ok ok
finish_embedded_ui_setup "$CONTAINER" "$FIN_DIR" > "$TMP/out"
wait
check_file_has "finish manual: steps heading" "$TMP/out" "Create the first Explorer user before you sign in"
check_file_has "finish manual: reason" "$TMP/out" "An earlier install created the operator token"
check_file_has "finish manual: the command keeps the token off the command line" "$TMP/out" "INFLUXDB3_AUTH_TOKEN=<operator token> docker exec -e INFLUXDB3_AUTH_TOKEN $CONTAINER influxdb3 create user --username admin --role Admin --require-password-reset"
check_file_has "finish manual: sign-in step" "$TMP/out" "Open Explorer UI: http://localhost:8181 and sign in as that user."
check_file_lacks "finish manual: browser not opened" "$SHIM_LOG" "open "
if [ -f "$FIN_DIR/.env" ]; then fail "finish manual: nothing must be recorded"; else pass; fi
check_equal "finish manual: EXPLORER_USER stays empty" "" "$EXPLORER_USER"

# Smoke check fails: user still created and recorded, browser not opened
EXPLORER_USER=""
reset_shims new ok fail
finish_embedded_ui_setup "$CONTAINER" "$FIN_DIR" > "$TMP/out"
wait
check_file_has "finish no-response: wording" "$TMP/out" "Checking InfluxDB 3 Explorer...no response"
check_file_has "finish no-response: deployed without Explorer wording" "$TMP/out" "InfluxDB 3 Enterprise successfully deployed"
check_file_has "finish no-response: log hint" "$TMP/out" "If the page does not load, check: docker logs $CONTAINER"
check_file_lacks "finish no-response: browser not opened" "$SHIM_LOG" "open "
check_equal "finish no-response: user still recorded" "admin" "$(read_env_value "$FIN_DIR/.env" EXPLORER_USER)"

# The CLI fails: the token exists now, so the steps are shown
EXPLORER_USER=""
rm -f "$FIN_DIR/.env"
reset_shims new fail ok
finish_embedded_ui_setup "$CONTAINER" "$FIN_DIR" > "$TMP/out"
wait
check_file_has "finish failed: reason shown" "$TMP/out" "The first Explorer user was not created: Create command failed: unauthorized"
check_file_has "finish failed: steps shown" "$TMP/out" "The server holds an operator token now"
check_file_lacks "finish failed: browser not opened" "$SHIM_LOG" "open "
if [ -f "$FIN_DIR/.env" ]; then fail "finish failed: nothing must be recorded"; else pass; fi

# The token API does not answer: nothing recorded, browser closed, warning shown
EXPLORER_USER=""
rm -f "$FIN_DIR/.env"
reset_shims fail ok ok
finish_embedded_ui_setup "$CONTAINER" "$FIN_DIR" > "$TMP/out"
wait
check_file_has "finish no_token: reason" "$TMP/out" "The operator token could not be created: the API at http://localhost:8181 did not return one."
check_file_has "finish no_token: re-run hint" "$TMP/out" "Re-run this script once the server is healthy (check: docker logs $CONTAINER)."
check_file_has "finish no_token: open window warning" "$TMP/out" "the first client to open http://localhost:8181 becomes the admin"
check_file_lacks "finish no_token: browser not opened" "$SHIM_LOG" "open "
check_file_lacks "finish no_token: no create user call" "$SHIM_LOG" "create user"
if [ -f "$FIN_DIR/.env" ]; then fail "finish no_token: nothing must be recorded"; else pass; fi
check_equal "finish no_token: EXPLORER_USER stays empty" "" "$EXPLORER_USER"

# The user exists but .env lost the record: the CLI says so, the run records it and opens the browser
EXPLORER_USER=""
rm -f "$FIN_DIR/.env"
mkdir -p "$FIN_DIR/explorer/config"
printf '{\n  "DEFAULT_API_TOKEN": "%s"\n}\n' "$TOKEN_FIXTURE" > "$FIN_DIR/explorer/config/config.json"
reset_shims conflict exists ok
finish_embedded_ui_setup "$CONTAINER" "$FIN_DIR" > "$TMP/out"
wait
check_file_has "finish exists-from-cli: create user was tried" "$SHIM_LOG" "create user"
check_file_has "finish exists-from-cli: open UI line" "$TMP/out" "Open Explorer UI: http://localhost:8181"
check_file_has "finish exists-from-cli: browser opened" "$SHIM_LOG" "open http://localhost:8181"
check_equal "finish exists-from-cli: user recorded" "admin" "$(read_env_value "$FIN_DIR/.env" EXPLORER_USER)"
check_equal "finish exists-from-cli: EXPLORER_USER set for the caller" admin "$EXPLORER_USER"
check_file_lacks "finish exists-from-cli: no sign-in box" "$TMP/out" "EXPLORER SIGN-IN"
check_file_lacks "finish exists-from-cli: no manual steps" "$TMP/out" "Create the first Explorer user before you sign in"
rm -rf "$FIN_DIR/explorer"

# .env cannot be written: the user is created, the warning shows, the run goes on
EXPLORER_USER=""
rm -f "$FIN_DIR/.env"
chmod 555 "$FIN_DIR"
reset_shims new ok ok
finish_embedded_ui_setup "$CONTAINER" "$FIN_DIR" > "$TMP/out" 2>/dev/null
wait
chmod 755 "$FIN_DIR"
if [ -f "$FIN_DIR/.env" ]; then
    printf 'skip: %s was writable without permission (root?); the record-failure check did not run\n' "$FIN_DIR"
else
    check_file_has "finish record failure: warning" "$TMP/out" "Warning: Could not record the Explorer user in $FIN_DIR/.env; the next run repeats this step"
    check_file_has "finish record failure: sign-in box still shown" "$TMP/out" "EXPLORER SIGN-IN"
    check_file_has "finish record failure: browser opened" "$SHIM_LOG" "open http://localhost:8181"
fi

# --- setup_docker_compose end to end with the shims ---
# The production sequence: a fresh embedded run, a re-run, and a Core run in
# between, each checked on the .env it leaves behind
load_function setup_docker_compose
load_function check_docker
load_function is_missing_image_error
load_function check_docker_image
load_function pull_docker_image
load_function filter_docker_output
load_function wait_for_container_ready
load_function port_in_use
load_function find_next_available_port
load_function openssl_pkcs1_key
load_function generate_jwt_private_key
load_function configure_explorer_via_file
PORT_PROBE=""
STARTUP_TIMEOUT_CORE=30
STARTUP_TIMEOUT_ENTERPRISE=90
INFLUXDB_VERSION_FLAG_SET="0"
HOME="$TMP/home-e2e"
mkdir -p "$HOME"
E2E_DIR="$HOME/.influxdb/docker"

# Runs setup_docker_compose as the script would: in its own process, with no
# value left over from an earlier call or test, and with no stdin for prompts.
# Output goes to $TMP/out; the exit status is the function's.
run_setup() {
    (
        unset EXPLORER_USER SESSION_SECRET JWT_PRIVATE_KEY LICENSE_EMAIL LICENSE_TYPE LICENSE_PROMPTED
        setup_docker_compose "$@" < /dev/null
        RC=$?
        wait
        exit "$RC"
    ) > "$TMP/out" 2>&1
}

# Fresh Enterprise 3.12.1 run
EDITION="Enterprise"; INFLUXDB_VERSION="3.12.1"; DOCKER_IMAGE="influxdb:3.12.1-enterprise"
INFLUXDB_PORT=8181; EXPLORER_PORT=8888
reset_shims new ok ok
run_setup enterprise "$E2E_DIR" "user@example.com" trial; RC=$?
check_equal "e2e fresh: returns 0" 0 "$RC"
check_file_has "e2e fresh: image pulled" "$SHIM_LOG" "docker compose pull influxdb3-enterprise"
check_file_has "e2e fresh: key generated with the image's openssl" "$SHIM_LOG" "docker run --rm --entrypoint openssl influxdb:3.12.1-enterprise genrsa -traditional 4096"
check_file_has "e2e fresh: server started" "$SHIM_LOG" "docker compose up -d influxdb3-enterprise"
check_file_has "e2e fresh: user created" "$SHIM_LOG" "docker exec -e INFLUXDB3_AUTH_TOKEN influxdb3-enterprise influxdb3 create user --username admin --role Admin --require-password-reset"
check_file_has "e2e fresh: browser opened" "$SHIM_LOG" "open http://localhost:8181"
check_file_has "e2e fresh: token box" "$TMP/out" "OPERATOR TOKEN: Save this token. It will not be shown again."
check_file_has "e2e fresh: sign-in box" "$TMP/out" "EXPLORER SIGN-IN"
check_file_has "e2e fresh: compose has the webui flags" "$E2E_DIR/docker-compose.yml" "- --mode=all,webui"
check_file_lacks "e2e fresh: no Explorer service" "$E2E_DIR/docker-compose.yml" "influxdb3-explorer"
E2E_SECRET=$(read_env_value "$E2E_DIR/.env" SESSION_SECRET)
check_status "e2e fresh: .env has a valid session secret" 0 is_session_secret "$E2E_SECRET"
check_equal "e2e fresh: .env has the email" "user@example.com" "$(read_env_value "$E2E_DIR/.env" INFLUXDB_EMAIL)"
check_equal "e2e fresh: .env has the license type" "trial" "$(read_env_value "$E2E_DIR/.env" INFLUXDB_LICENSE_TYPE)"
check_equal "e2e fresh: .env records the user" "admin" "$(read_env_value "$E2E_DIR/.env" EXPLORER_USER)"
check_equal "e2e fresh: .env holds the generated key" "$PKCS1" "$(read_env_jwt_private_key "$E2E_DIR/.env")"
if [ -e "$E2E_DIR/explorer" ]; then fail "e2e fresh: explorer/ must not be created"; else pass; fi

# Re-run: the token exists, the record is kept, nothing is created again.
# The server wrote its license file during the first run, which is what
# skips the license prompt on a real re-run
mkdir -p "$HOME/.influxdb/data/cluster0"
: > "$HOME/.influxdb/data/cluster0/trial_or_home_license"
reset_shims conflict ok ok
run_setup enterprise "$E2E_DIR" "" ""; RC=$?
check_equal "e2e re-run: returns 0" 0 "$RC"
check_file_has "e2e re-run: existing stack stopped first" "$SHIM_LOG" "docker compose down"
check_file_lacks "e2e re-run: no new key" "$SHIM_LOG" "--entrypoint openssl"
check_file_lacks "e2e re-run: no create user call" "$SHIM_LOG" "create user"
check_file_lacks "e2e re-run: no token box" "$TMP/out" "OPERATOR TOKEN"
check_file_has "e2e re-run: browser opened" "$SHIM_LOG" "open http://localhost:8181"
check_equal "e2e re-run: session secret kept" "$E2E_SECRET" "$(read_env_value "$E2E_DIR/.env" SESSION_SECRET)"
check_equal "e2e re-run: email kept without a prompt" "user@example.com" "$(read_env_value "$E2E_DIR/.env" INFLUXDB_EMAIL)"
check_equal "e2e re-run: license type kept" "trial" "$(read_env_value "$E2E_DIR/.env" INFLUXDB_LICENSE_TYPE)"
check_equal "e2e re-run: user record kept" "admin" "$(read_env_value "$E2E_DIR/.env" EXPLORER_USER)"
check_equal "e2e re-run: key kept" "$PKCS1" "$(read_env_jwt_private_key "$E2E_DIR/.env")"

# Core run in between: the Explorer container path, which must keep the key and the record
EDITION="Core"; INFLUXDB_VERSION="3.12.1"; DOCKER_IMAGE="influxdb:3.12.1-core"
reset_shims conflict ok ok
run_setup core "$E2E_DIR" "" ""; RC=$?
check_equal "e2e core: returns 0" 0 "$RC"
check_file_has "e2e core: compose has the Explorer service" "$E2E_DIR/docker-compose.yml" "influxdb3-explorer:"
check_file_lacks "e2e core: no webui flags" "$E2E_DIR/docker-compose.yml" "webui"
check_file_lacks "e2e core: no create user call" "$SHIM_LOG" "create user"
check_equal "e2e core: session secret kept" "$E2E_SECRET" "$(read_env_value "$E2E_DIR/.env" SESSION_SECRET)"
check_equal "e2e core: key kept for the next embedded run" "$PKCS1" "$(read_env_jwt_private_key "$E2E_DIR/.env")"
check_equal "e2e core: user record kept for the next embedded run" "admin" "$(read_env_value "$E2E_DIR/.env" EXPLORER_USER)"
check_file_lacks "e2e core: no email for Core" "$E2E_DIR/.env" "INFLUXDB_EMAIL"

# Back to Enterprise 3.12.1: still nothing to create
EDITION="Enterprise"; INFLUXDB_VERSION="3.12.1"; DOCKER_IMAGE="influxdb:3.12.1-enterprise"
reset_shims conflict ok ok
run_setup enterprise "$E2E_DIR" "" ""; RC=$?
check_equal "e2e back to embedded: returns 0" 0 "$RC"
check_file_lacks "e2e back to embedded: no create user call" "$SHIM_LOG" "create user"
check_file_lacks "e2e back to embedded: no new key" "$SHIM_LOG" "--entrypoint openssl"
check_file_has "e2e back to embedded: open UI line" "$TMP/out" "Open Explorer UI: http://localhost:8181"
check_equal "e2e back to embedded: key kept" "$PKCS1" "$(read_env_jwt_private_key "$E2E_DIR/.env")"

# A re-run whose stored key is malformed: the key is generated again after
# the pull and .env is written a second time; the record must survive that
write_env_file enterprise "$E2E_SECRET" "user@example.com" "$E2E_DIR" trial "$PKCS8" admin
reset_shims conflict ok ok
run_setup enterprise "$E2E_DIR" "" ""; RC=$?
check_equal "e2e bad key: returns 0" 0 "$RC"
check_file_has "e2e bad key: warning" "$TMP/out" "Warning: JWT_PRIVATE_KEY in $E2E_DIR/.env is not a PKCS#1 RSA key; generating a new one. Users will need to sign in again."
check_file_has "e2e bad key: key generated again" "$SHIM_LOG" "--entrypoint openssl"
check_file_lacks "e2e bad key: no create user call" "$SHIM_LOG" "create user"
check_equal "e2e bad key: .env holds the new key" "$PKCS1" "$(read_env_jwt_private_key "$E2E_DIR/.env")"
check_equal "e2e bad key: user record survives the second write" "admin" "$(read_env_value "$E2E_DIR/.env" EXPLORER_USER)"
check_equal "e2e bad key: session secret kept" "$E2E_SECRET" "$(read_env_value "$E2E_DIR/.env" SESSION_SECRET)"
check_equal "e2e bad key: email kept" "user@example.com" "$(read_env_value "$E2E_DIR/.env" INFLUXDB_EMAIL)"

# --- Key-generation retries and fallbacks ---
# These commands replace host generators too, so the result does not depend
# on the OpenSSL version or ssh-keygen installed on the test machine.
KEYGEN_BIN="$TMP/keygen-bin"
mkdir -p "$KEYGEN_BIN" "$TMP/keygen-scratch"
cat > "$KEYGEN_BIN/openssl" <<'STUB'
#!/bin/sh
printf 'openssl %s\n' "$*" >> "$SHIM_LOG"
case "${SHIM_HOST_KEY:-fail}" in
    pkcs1) printf '%s\n' "$SHIM_PKCS1" ;;
    *) exit 1 ;;
esac
STUB
cat > "$KEYGEN_BIN/ssh-keygen" <<'STUB'
#!/bin/sh
printf 'ssh-keygen %s\n' "$*" >> "$SHIM_LOG"
[ "${SHIM_SSH_KEY:-fail}" = pkcs1 ] || exit 1
while [ "$#" -gt 0 ]; do
    if [ "$1" = -f ]; then
        printf '%s\n' "$SHIM_PKCS1" > "$2"
        exit 0
    fi
    shift
done
exit 1
STUB
chmod +x "$KEYGEN_BIN/openssl" "$KEYGEN_BIN/ssh-keygen"
PATH="$KEYGEN_BIN:$PATH"
SHIM_PKCS8="$PKCS8"
SHIM_HOST_KEY=fail
SHIM_SSH_KEY=fail
export SHIM_PKCS8 SHIM_IMAGE_KEY SHIM_HOST_KEY SHIM_SSH_KEY

reset_shims
SHIM_IMAGE_KEY=openssl3
KEY_OUTPUT=$(generate_jwt_private_key "$DOCKER_IMAGE"); RC=$?
check_equal "key image: returns 0" 0 "$RC"
check_equal "key image: returns the key" "$PKCS1" "$KEY_OUTPUT"
check_file_has "key image: tries -traditional first" "$SHIM_LOG" "docker run --rm --entrypoint openssl $DOCKER_IMAGE genrsa -traditional 4096"
check_file_lacks "key image: no unnecessary retry" "$SHIM_LOG" "$DOCKER_IMAGE genrsa 4096"
check_file_lacks "key image: no host fallback" "$SHIM_LOG" "openssl genrsa"

reset_shims
SHIM_IMAGE_KEY=libressl
KEY_OUTPUT=$(generate_jwt_private_key "$DOCKER_IMAGE"); RC=$?
check_equal "key LibreSSL: returns 0 after retry" 0 "$RC"
check_equal "key LibreSSL: returns PKCS1" "$PKCS1" "$KEY_OUTPUT"
check_file_has "key LibreSSL: retries without -traditional" "$SHIM_LOG" "docker run --rm --entrypoint openssl $DOCKER_IMAGE genrsa 4096"
check_file_lacks "key LibreSSL: no host fallback" "$SHIM_LOG" "openssl genrsa"

reset_shims
SHIM_IMAGE_KEY=fail
SHIM_HOST_KEY=pkcs1
KEY_OUTPUT=$(generate_jwt_private_key "$DOCKER_IMAGE"); RC=$?
check_equal "key host: returns 0" 0 "$RC"
check_equal "key host: returns the key" "$PKCS1" "$KEY_OUTPUT"
check_file_has "key host: exhausts image retries" "$SHIM_LOG" "$DOCKER_IMAGE genrsa 4096"
check_file_has "key host: calls host OpenSSL" "$SHIM_LOG" "openssl genrsa -traditional 4096"
check_file_lacks "key host: stops before ssh-keygen" "$SHIM_LOG" "ssh-keygen"

reset_shims
SHIM_HOST_KEY=fail
SHIM_SSH_KEY=pkcs1
KEY_OUTPUT=$(TMPDIR="$TMP/keygen-scratch" generate_jwt_private_key "$DOCKER_IMAGE"); RC=$?
check_equal "key ssh: returns 0" 0 "$RC"
check_equal "key ssh: returns the key" "$PKCS1" "$KEY_OUTPUT"
check_file_has "key ssh: exhausts host retries" "$SHIM_LOG" "openssl genrsa 4096"
check_file_has "key ssh: uses PEM RSA" "$SHIM_LOG" "ssh-keygen -q -m PEM -t rsa -b 4096 -N  -f"
check_equal "key ssh: removes its temporary files" "" "$(ls -A "$TMP/keygen-scratch")"

reset_shims
SHIM_SSH_KEY=fail
KEY_OUTPUT=$(TMPDIR="$TMP/keygen-scratch" generate_jwt_private_key "$DOCKER_IMAGE"); RC=$?
check_equal "key failure: returns 1" 1 "$RC"
check_equal "key failure: prints no key" "" "$KEY_OUTPUT"
check_file_has "key failure: tries the last generator" "$SHIM_LOG" "ssh-keygen"
check_equal "key failure: removes its temporary files" "" "$(ls -A "$TMP/keygen-scratch")"

# Exercise the real orchestration failure branch with every generator failing.
reset_shims
run_setup enterprise "$TMP/key-failure" "user@example.com" trial; RC=$?
check_equal "setup key failure: returns 1" 1 "$RC"
check_file_has "setup key failure: explains the failure" "$TMP/out" "Could not generate an RSA key"
check_file_lacks "setup key failure: never starts a container" "$SHIM_LOG" "docker compose up"

# --- Binary path: embedded Explorer UI helpers (Enterprise 3.12.0+) ---
# The host-generator stubs above stay on PATH, so the signing key comes from
# the openssl stub and the tests never run a real generator.
load_function write_private_file
load_function load_webui_session_secret
load_function load_webui_jwt_private_key
load_function setup_embedded_ui
load_function check_embedded_ui
load_function display_enterprise_server_command
load_function display_enterprise_manual_command

# The shell keeps the last definition of a name while load_function reads
# the first, so a name defined twice would hide the body that production runs
check_equal "no function is defined twice in the script" "" "$(grep -E '^[A-Za-z_][A-Za-z0-9_]*\(\) \{$' "$SCRIPT" | sort | uniq -d)"

BIN_HOME="$TMP/binary-home"
INSTALL_LOC="$BIN_HOME/.influxdb"
WEBUI_SECRET_FILE="$INSTALL_LOC/webui-session-secret"
JWT_KEY_FILE="$INSTALL_LOC/jwt-private-key.pem"
mkdir -p "$INSTALL_LOC"

# run_loader FUNCTION VARIABLE: runs a loader in its own process, as the
# script would, and prints the exported VARIABLE as a child process sees it.
# Stderr goes to $TMP/err; the status is the loader's.
run_loader() {
    (
        unset INFLUXDB3_WEBUI_SESSION_SECRET INFLUXDB3_JWT_PRIVATE_KEY
        "$1" 2> "$TMP/err" || exit $?
        sh -c "printf '%s' \"\$$2\""
    ) > "$TMP/loader-out"
}

# write_private_file: an existing readable file must not be rewritten in
# place. A descriptor opened on the old file before the write stands in for
# a reader who waits for the new secret.
PRIV="$TMP/private-file"
printf 'old\n' > "$PRIV"
chmod 644 "$PRIV"
exec 3< "$PRIV"
check_status "write_private_file over a 644 file succeeds" 0 write_private_file "$PRIV" "new-secret"
check_equal "write_private_file: new content" "new-secret" "$(cat "$PRIV")"
check_equal "write_private_file: mode 600 after the write" "-rw-------" "$(ls -l "$PRIV" | cut -c1-10)"
check_equal "write_private_file: an already-open descriptor cannot read the new secret" "old" "$(cat <&3)"
exec 3<&-
rm -f "$PRIV"
check_status "write_private_file creates a missing file" 0 write_private_file "$PRIV" "fresh"
check_equal "write_private_file: new file content" "fresh" "$(cat "$PRIV")"
check_equal "write_private_file: new file mode 600" "-rw-------" "$(ls -l "$PRIV" | cut -c1-10)"
# A failed redirection gives status 1 in bash and 2 in dash; the callers test
# for nonzero only
if write_private_file "$TMP/nowhere/file" "x" 2>/dev/null; then fail "write_private_file into a missing directory must fail"; else pass; fi

# load_webui_session_secret
rm -f "$WEBUI_SECRET_FILE"
run_loader load_webui_session_secret INFLUXDB3_WEBUI_SESSION_SECRET; RC=$?
check_equal "session secret: a missing file gives status 0" 0 "$RC"
check_status "session secret: a new secret is exported" 0 is_session_secret "$(cat "$TMP/loader-out")"
check_equal "session secret: the file holds the exported secret" "$(cat "$TMP/loader-out")" "$(cat "$WEBUI_SECRET_FILE")"
check_equal "session secret: the new file is mode 600" "-rw-------" "$(ls -l "$WEBUI_SECRET_FILE" | cut -c1-10)"
check_equal "session secret: a new file prints no warning" "" "$(cat "$TMP/err")"

printf '%s\n' "$HEX64" > "$WEBUI_SECRET_FILE"
run_loader load_webui_session_secret INFLUXDB3_WEBUI_SESSION_SECRET; RC=$?
check_equal "session secret: a valid file gives status 0" 0 "$RC"
check_equal "session secret: a valid file is reused unchanged" "$HEX64" "$(cat "$TMP/loader-out")"
check_equal "session secret: reuse prints no warning" "" "$(cat "$TMP/err")"

printf 'abc\n' > "$WEBUI_SECRET_FILE"
chmod 644 "$WEBUI_SECRET_FILE"
run_loader load_webui_session_secret INFLUXDB3_WEBUI_SESSION_SECRET; RC=$?
check_equal "session secret: a malformed file gives status 0" 0 "$RC"
check_file_has "session secret: a malformed file warns" "$TMP/err" "Warning: '$WEBUI_SECRET_FILE' does not hold a usable session secret; generating a new one"
check_status "session secret: a malformed file is replaced by a valid secret" 0 is_session_secret "$(cat "$TMP/loader-out")"
check_equal "session secret: the replacement is written" "$(cat "$TMP/loader-out")" "$(cat "$WEBUI_SECRET_FILE")"
check_equal "session secret: a 644 file is mode 600 after the replacement" "-rw-------" "$(ls -l "$WEBUI_SECRET_FILE" | cut -c1-10)"

rm -f "$WEBUI_SECRET_FILE"
chmod 555 "$INSTALL_LOC"
run_loader load_webui_session_secret INFLUXDB3_WEBUI_SESSION_SECRET; RC=$?
chmod 755 "$INSTALL_LOC"
if [ -f "$WEBUI_SECRET_FILE" ]; then
    printf 'skip: %s was writable without permission (root?); the unwritable-directory checks did not run\n' "$INSTALL_LOC"
else
    check_equal "session secret: an unwritable directory gives status 1" 1 "$RC"
    check_file_has "session secret: an unwritable directory is reported" "$TMP/err" "Could not write the Explorer session secret to '$WEBUI_SECRET_FILE'"
    check_equal "session secret: nothing is exported on failure" "" "$(cat "$TMP/loader-out")"
fi

# load_webui_jwt_private_key
rm -f "$JWT_KEY_FILE"
reset_shims
SHIM_HOST_KEY=pkcs1
run_loader load_webui_jwt_private_key INFLUXDB3_JWT_PRIVATE_KEY; RC=$?
check_equal "webui key: a missing file gives status 0" 0 "$RC"
check_equal "webui key: the generated key is exported" "$PKCS1" "$(cat "$TMP/loader-out")"
check_equal "webui key: the file holds the generated key" "$PKCS1" "$(cat "$JWT_KEY_FILE")"
check_equal "webui key: the new file is mode 600" "-rw-------" "$(ls -l "$JWT_KEY_FILE" | cut -c1-10)"
check_file_has "webui key: the host openssl is used" "$SHIM_LOG" "openssl genrsa -traditional 4096"
check_file_lacks "webui key: no image openssl on the binary path" "$SHIM_LOG" "docker"
check_equal "webui key: a new file prints no warning" "" "$(cat "$TMP/err")"

reset_shims
SHIM_HOST_KEY=fail
run_loader load_webui_jwt_private_key INFLUXDB3_JWT_PRIVATE_KEY; RC=$?
check_equal "webui key: a valid file gives status 0" 0 "$RC"
check_equal "webui key: a valid file is reused unchanged" "$PKCS1" "$(cat "$TMP/loader-out")"
check_file_lacks "webui key: reuse runs no generator" "$SHIM_LOG" "openssl"
check_equal "webui key: reuse prints no warning" "" "$(cat "$TMP/err")"

printf '%s\n' "$PKCS8" > "$JWT_KEY_FILE"
reset_shims
SHIM_HOST_KEY=pkcs1
run_loader load_webui_jwt_private_key INFLUXDB3_JWT_PRIVATE_KEY; RC=$?
check_equal "webui key: a PKCS#8 file gives status 0" 0 "$RC"
check_file_has "webui key: a PKCS#8 file warns" "$TMP/err" "Warning: '$JWT_KEY_FILE' is not a PKCS#1 RSA private key; generating a new one. Users will need to sign in again."
check_equal "webui key: a PKCS#8 file is replaced by a PKCS#1 key" "$PKCS1" "$(cat "$TMP/loader-out")"
check_equal "webui key: the replacement is written" "$PKCS1" "$(cat "$JWT_KEY_FILE")"

rm -f "$JWT_KEY_FILE"
reset_shims
SHIM_HOST_KEY=fail
SHIM_SSH_KEY=fail
run_loader load_webui_jwt_private_key INFLUXDB3_JWT_PRIVATE_KEY; RC=$?
check_equal "webui key: failing generators give status 1" 1 "$RC"
check_file_has "webui key: failing generators are reported" "$TMP/err" "Could not generate the JWT signing key. Install openssl or ssh-keygen and run this script again."
check_file_has "webui key: ssh-keygen is tried last" "$SHIM_LOG" "ssh-keygen"
check_equal "webui key: nothing is exported on failure" "" "$(cat "$TMP/loader-out")"
if [ -e "$JWT_KEY_FILE" ]; then fail "webui key: no file is written on failure"; else pass; fi

# The same with no generator on PATH at all: only the commands the loader
# itself needs are reachable
NOGEN_BIN="$TMP/nogen-bin"
mkdir -p "$NOGEN_BIN"
for tool in cat chmod rm sh; do
    ln -s "$(PATH="$ORIG_PATH" command -v "$tool")" "$NOGEN_BIN/$tool"
done
reset_shims
(
    PATH="$NOGEN_BIN"
    export PATH
    run_loader load_webui_jwt_private_key INFLUXDB3_JWT_PRIVATE_KEY
); RC=$?
check_equal "webui key: no generator on PATH gives status 1" 1 "$RC"
check_file_has "webui key: no generator on PATH is reported" "$TMP/err" "Could not generate the JWT signing key"
check_equal "webui key: no generator on PATH runs no stub" "" "$(cat "$SHIM_LOG")"

reset_shims
SHIM_HOST_KEY=pkcs1
chmod 555 "$INSTALL_LOC"
run_loader load_webui_jwt_private_key INFLUXDB3_JWT_PRIVATE_KEY; RC=$?
chmod 755 "$INSTALL_LOC"
if [ -f "$JWT_KEY_FILE" ]; then
    printf 'skip: %s was writable without permission (root?); the unwritable-directory key checks did not run\n' "$INSTALL_LOC"
    rm -f "$JWT_KEY_FILE"
else
    check_equal "webui key: an unwritable directory gives status 1" 1 "$RC"
    check_file_has "webui key: an unwritable directory is reported" "$TMP/err" "Could not write the JWT signing key to '$JWT_KEY_FILE'"
    check_equal "webui key: nothing is exported when the write fails" "" "$(cat "$TMP/loader-out")"
fi

# setup_embedded_ui: the gate the main flow runs before the startup prompt.
# run_gate prints the three variables it sets and then the two exports as a
# child process sees them.
run_gate() {
    (
        unset INFLUXDB3_WEBUI_SESSION_SECRET INFLUXDB3_JWT_PRIVATE_KEY
        setup_embedded_ui || exit $?
        printf '%s|%s|%s\n' "$USE_EMBEDDED_UI" "$UI_FLAGS" "$UI_READY"
        sh -c 'printf "%s\n" "${INFLUXDB3_WEBUI_SESSION_SECRET:-unset}"'
        sh -c 'printf "%s\n" "${INFLUXDB3_JWT_PRIVATE_KEY:-unset}"'
    ) > "$TMP/gate-out" 2> "$TMP/err"
}
rm -f "$WEBUI_SECRET_FILE" "$JWT_KEY_FILE"
reset_shims
SHIM_HOST_KEY=pkcs1

EDITION="Enterprise"; INFLUXDB_VERSION="3.11.7"
run_gate; RC=$?
check_equal "gate 3.11.7: returns 0" 0 "$RC"
check_equal "gate 3.11.7: UI off, no flags" "false||false" "$(sed -n 1p "$TMP/gate-out")"
check_equal "gate 3.11.7: no session secret exported" "unset" "$(sed -n 2p "$TMP/gate-out")"
check_equal "gate 3.11.7: no signing key exported" "unset" "$(sed -n 3p "$TMP/gate-out")"
if [ -e "$WEBUI_SECRET_FILE" ] || [ -e "$JWT_KEY_FILE" ]; then fail "gate 3.11.7: no secret files must be created"; else pass; fi
check_file_lacks "gate 3.11.7: no generator runs" "$SHIM_LOG" "openssl"

EDITION="Core"; INFLUXDB_VERSION="3.12.0"
run_gate; RC=$?
check_equal "gate Core 3.12.0: returns 0" 0 "$RC"
check_equal "gate Core 3.12.0: UI off, no flags" "false||false" "$(sed -n 1p "$TMP/gate-out")"
if [ -e "$WEBUI_SECRET_FILE" ] || [ -e "$JWT_KEY_FILE" ]; then fail "gate Core 3.12.0: no secret files must be created"; else pass; fi

EDITION="Enterprise"; INFLUXDB_VERSION="3.12.0"
run_gate; RC=$?
check_equal "gate 3.12.0: returns 0" 0 "$RC"
check_equal "gate 3.12.0: UI on with the serve flags" "true|--mode=all,webui --user-auth-type=basic --jwt-key-id=install-script|false" "$(sed -n 1p "$TMP/gate-out")"
check_status "gate 3.12.0: a session secret is exported" 0 is_session_secret "$(sed -n 2p "$TMP/gate-out")"
check_equal "gate 3.12.0: the signing key is exported" "$PKCS1" "$(sed -n '3,$p' "$TMP/gate-out")"
check_equal "gate 3.12.0: the secret file is mode 600" "-rw-------" "$(ls -l "$WEBUI_SECRET_FILE" | cut -c1-10)"
check_equal "gate 3.12.0: the key file is mode 600" "-rw-------" "$(ls -l "$JWT_KEY_FILE" | cut -c1-10)"
check_file_has "gate 3.12.0: the key comes from the host openssl" "$SHIM_LOG" "openssl genrsa -traditional 4096"
GATE_SECRET=$(sed -n 2p "$TMP/gate-out")

reset_shims
SHIM_HOST_KEY=fail
run_gate; RC=$?
check_equal "gate re-run: returns 0" 0 "$RC"
check_equal "gate re-run: the session secret is kept" "$GATE_SECRET" "$(sed -n 2p "$TMP/gate-out")"
check_equal "gate re-run: the signing key is kept" "$PKCS1" "$(sed -n '3,$p' "$TMP/gate-out")"
check_file_lacks "gate re-run: no generator runs" "$SHIM_LOG" "openssl"
check_equal "gate re-run: no warning" "" "$(cat "$TMP/err")"

# The main flow is not a function. Check in place that the gate runs once,
# that every Enterprise serve line passes the flags, and that the summary
# branches on the gate's result.
check_equal "main flow: setup_embedded_ui runs once" 1 "$(grep -c '^setup_embedded_ui$' "$SCRIPT")"
ENT_SERVE=$(grep -cE '^ *"\$INSTALL_LOC/\$BINARY_NAME" serve --cluster-id=' "$SCRIPT")
check_equal "main flow: three Enterprise serve lines" 3 "$ENT_SERVE"
check_equal "main flow: every Enterprise serve line passes \$UI_FLAGS" "$ENT_SERVE" "$(grep -E '^ *"\$INSTALL_LOC/\$BINARY_NAME" serve --cluster-id=' "$SCRIPT" | grep -cF ' $UI_FLAGS ')"
check_equal "main flow: no serve line passes a secret as a flag" 0 "$(grep -E '^ *"\$INSTALL_LOC/\$BINARY_NAME" serve ' "$SCRIPT" | grep -cE 'webui-session-secret|jwt-private-key')"
check_equal "main flow: Core serve lines pass no UI flags" 0 "$(grep -E '^ *"\$INSTALL_LOC/\$BINARY_NAME" serve --node-id=' "$SCRIPT" | grep -cF 'UI_FLAGS')"
# These lines have look-alikes on the Docker path and in the summary, so
# each check is pinned to its own place: the call line and the line before
# it, the summary section, or column 0
UI_CHECK_LINE=$(grep -n -x -F '        check_embedded_ui' "$SCRIPT" | cut -d: -f1)
check_equal "main flow: check_embedded_ui is called once" 1 "$(printf '%s\n' "$UI_CHECK_LINE" | grep -c .)"
check_equal "main flow: the UI check runs only after a successful start" '    if [ "$USE_EMBEDDED_UI" = true ] && [ "${SUCCESS:-0}" -eq 1 ]; then' "$(sed -n "$((${UI_CHECK_LINE:-0} - 1))p" "$SCRIPT" 2>/dev/null)"
SUMMARY=$(sed -n '/^### SUCCESS INFORMATION ###$/,$p' "$SCRIPT")
check_equal "main flow: the summary points to the log when the UI did not answer" 1 "$(printf '%s\n' "$SUMMARY" | grep -c -F 'If the page does not load, check the log: %s')"
check_equal "main flow: the log hint is gated on UI_READY" 1 "$(printf '%s\n' "$SUMMARY" | grep -c -F 'if [ "$UI_READY" = false ]; then')"
check_equal "main flow: the external Explorer banner is gated at top level on no embedded UI" 1 "$(grep -c -x -F 'if [ "$USE_EMBEDDED_UI" = false ]; then' "$SCRIPT")"
check_equal "main flow: the banner sits inside that gate" 1 "$(sed -n '/^if \[ "\$USE_EMBEDDED_UI" = false \]; then$/,/^fi$/p' "$SCRIPT" | grep -c -F 'Get InfluxDB 3 Explorer')"

# check_embedded_ui: the curl shim answers / per SHIM_SMOKE; the open shim
# logs the browser call
PORT=8181
reset_shims new ok ok
check_embedded_ui > "$TMP/out"
wait
check_equal "ui check ok: UI_READY is true" true "$UI_READY"
check_file_has "ui check ok: one request to /" "$SHIM_LOG" "curl -sf --max-time 5 -o /dev/null http://localhost:8181/"
check_file_has "ui check ok: served line" "$TMP/out" "Explorer is served by InfluxDB on port 8181"
check_file_has "ui check ok: browser opened" "$SHIM_LOG" "open http://localhost:8181"
check_equal "ui check ok: one request only" 1 "$(grep -c '^curl ' "$SHIM_LOG")"

reset_shims new ok fail
check_embedded_ui > "$TMP/out"
wait
check_equal "ui check failed: UI_READY is false" false "$UI_READY"
check_file_has "ui check failed: did-not-respond line" "$TMP/out" "Explorer did not respond at http://localhost:8181/"
check_file_lacks "ui check failed: browser not opened" "$SHIM_LOG" "open "

# display_enterprise_server_command and display_enterprise_manual_command:
# the UI lines appear only with the UI on, and no secret value is printed
CLUSTER_ID=cluster0; NODE_ID=node0; LICENSE_TYPE=trial; LICENSE_EMAIL=user@example.com
STORAGE_FLAGS_ECHO="--object-store=file --data-dir $INSTALL_LOC/data --plugin-dir $INSTALL_LOC/plugins"
UI_SECRET_LINE="INFLUXDB3_WEBUI_SESSION_SECRET=\"\$(cat '$WEBUI_SECRET_FILE')\""
UI_KEY_LINE="INFLUXDB3_JWT_PRIVATE_KEY=\"\$(cat '$JWT_KEY_FILE')\""

USE_EMBEDDED_UI=true
display_enterprise_server_command true > "$TMP/out"
check_file_has "quick start UI: session secret read from its file" "$TMP/out" "$UI_SECRET_LINE"
check_file_has "quick start UI: signing key read from its file" "$TMP/out" "$UI_KEY_LINE"
check_file_has "quick start UI: serve flags" "$TMP/out" "--mode=all,webui --user-auth-type=basic --jwt-key-id=install-script"
check_file_has "quick start UI: license flags kept" "$TMP/out" "--license-email=user@example.com"
check_file_lacks "quick start UI: secret value not printed" "$TMP/out" "$GATE_SECRET"
check_file_lacks "quick start UI: key value not printed" "$TMP/out" "BEGIN RSA PRIVATE KEY"

display_enterprise_server_command false > "$TMP/out"
check_file_has "custom start UI: session secret read from its file" "$TMP/out" "$UI_SECRET_LINE"
check_file_has "custom start UI: signing key read from its file" "$TMP/out" "$UI_KEY_LINE"
check_file_has "custom start UI: serve flags" "$TMP/out" "--mode='all,webui' --user-auth-type='basic' --jwt-key-id='install-script'"

USE_EMBEDDED_UI=false
display_enterprise_server_command true > "$TMP/out"
check_file_lacks "quick start no UI: no webui flags" "$TMP/out" "webui"
check_file_lacks "quick start no UI: no environment lines" "$TMP/out" "INFLUXDB3_"
check_file_has "quick start no UI: serve line kept" "$TMP/out" "influxdb3 serve"
display_enterprise_server_command false > "$TMP/out"
check_file_lacks "custom start no UI: no webui flags" "$TMP/out" "webui"
check_file_lacks "custom start no UI: no environment lines" "$TMP/out" "INFLUXDB3_"

# The manual command after Skip startup: nothing chosen yet, defaults shown
USE_EMBEDDED_UI=true
(
    unset CLUSTER_ID NODE_ID LICENSE_TYPE LICENSE_EMAIL STORAGE_FLAGS_ECHO
    display_enterprise_manual_command
) > "$TMP/out"
check_file_has "manual UI: session secret read from its file" "$TMP/out" "$UI_SECRET_LINE"
check_file_has "manual UI: signing key read from its file" "$TMP/out" "$UI_KEY_LINE"
check_file_has "manual UI: serve flags" "$TMP/out" "--mode=all,webui --user-auth-type=basic --jwt-key-id=install-script"
check_file_has "manual UI: default cluster id" "$TMP/out" "--cluster-id=cluster0"
check_file_has "manual UI: default node id" "$TMP/out" "--node-id=node0"
check_file_has "manual UI: default storage flags" "$TMP/out" "--object-store=file --data-dir $INSTALL_LOC/data --plugin-dir $INSTALL_LOC/plugins"
check_file_has "manual UI: bind line" "$TMP/out" "--http-bind=0.0.0.0:8181"
check_file_lacks "manual UI: secret value not printed" "$TMP/out" "$GATE_SECRET"
check_file_lacks "manual UI: key value not printed" "$TMP/out" "BEGIN RSA PRIVATE KEY"
USE_EMBEDDED_UI=false
display_enterprise_manual_command > "$TMP/out"
check_file_lacks "manual no UI: no webui flags" "$TMP/out" "webui"
check_file_lacks "manual no UI: no environment lines" "$TMP/out" "INFLUXDB3_"
check_file_has "manual no UI: serve line kept" "$TMP/out" "influxdb3 serve"

PATH="$ORIG_PATH"
export PATH

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
