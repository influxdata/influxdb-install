#!/bin/sh
# shellcheck disable=SC2034  # globals set here are read by the loaded functions
# Unit tests for the helper functions in install_influxdb.sh.
#
# The script runs its installation flow at load time, so the tests do not
# source it. Instead each test loads one function's definition from the file:
# the lines from "name() {" at column 0 to the next "}" at column 0.
#
# The commands those functions call (curl, docker, open, xdg-open) are
# replaced by shims in a scratch directory for the first-user tests, so no
# server and no Docker daemon is needed. The compose check alone runs the
# real "docker compose config" when Docker is present, and is skipped
# otherwise.
#
# Run: sh tests/test_install_functions.sh
# Exit status is 1 when a check fails. Needs only POSIX sh, sed, grep, od.
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

load_function() {
    BODY=$(sed -n "/^$1() {/,/^}/p" "$SCRIPT")
    if [ -z "$BODY" ]; then
        printf 'cannot find function %s in %s\n' "$1" "$SCRIPT" >&2
        exit 2
    fi
    eval "$BODY"
}

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
OLD_TOKEN_FIXTURE="apiv3_redacted_old"
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

# A Core run then an embedded run: the key written by the first survives
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
            ok) printf 'User created\nUsername: admin\nTemporary password: placeholder-temp\n'; exit 0 ;;
            exists) printf 'Create command failed: username already exists: admin\n' >&2; exit 1 ;;
            *) printf 'Create command failed: unauthorized\n' >&2; exit 1 ;;
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
export SHIM_NEW_TOKEN SHIM_TOKEN SHIM_SMOKE SHIM_CREATE

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
    *placeholder-temp*) pass ;;
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
printf '{\n  "DEFAULT_API_TOKEN": "%s"\n}\n' "$OLD_TOKEN_FIXTURE" > "$FU_DIR/explorer/config/config.json"
reset_shims conflict ok
setup_first_explorer_user "$CONTAINER" "$FU_DIR" "" > "$TMP/out"; RC=$?
check_equal "old layout: state is created" created "$FIRST_USER_STATE"
check_file_has "old layout: the stored token is used" "$SHIM_LOG" "env INFLUXDB3_AUTH_TOKEN=$OLD_TOKEN_FIXTURE"
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
check_file_has "finish fresh: CLI output shown" "$TMP/out" "Temporary password: placeholder-temp"
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

PATH="$ORIG_PATH"
export PATH

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
