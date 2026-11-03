#!/bin/sh
# shellcheck disable=SC2034  # globals set here are read by the loaded functions
# Unit tests for the helper functions in install_influxdb.sh.
#
# The script runs its installation flow at load time, so the tests do not
# source it. Instead each test loads one function's definition from the file:
# the lines from "name() {" at column 0 to the next "}" at column 0.
#
# Run: sh tests/test_install_functions.sh
# Exit status is 1 when a check fails. Needs only POSIX sh, sed, grep, od.
# The compose test also runs "docker compose config" when Docker is present.
set -u

# Byte-wise character ranges in the case patterns below
LC_ALL=C
export LC_ALL

# Docker reads its config and compose plugin from $HOME/.docker; keep the
# real one while the tests point HOME at a scratch directory
DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
export DOCKER_CONFIG

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

# Colour variables the functions print with; empty keeps the output plain
BOLD=""; DIM=""; BLUE=""; NC=""; YELLOW=""

load_function version_at_least
load_function has_embedded_ui
load_function predates_embedded_ui
load_function is_session_secret
load_function generate_session_secret
load_function is_jwt_private_key
load_function create_docker_directories
load_function generate_docker_compose_yaml
load_function write_env_file
load_function read_env_value
load_function read_env_jwt_private_key
load_function extract_token_from_explorer_config

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

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

# --- predates_embedded_ui ---
check_status "no earlier install does not predate" 1 predates_embedded_ui "" ""
check_status "earlier Core predates, any version" 0 predates_embedded_ui Core 3.12.1
check_status "earlier Enterprise, unknown version, predates" 0 predates_embedded_ui Enterprise ""
check_status "earlier Enterprise 3.11.0 predates" 0 predates_embedded_ui Enterprise 3.11.0
check_status "earlier floating tag 3 predates" 0 predates_embedded_ui Enterprise 3
check_status "earlier Enterprise 3.12.0 does not predate" 1 predates_embedded_ui Enterprise 3.12.0

# --- is_session_secret ---
HEX63=$(printf '%063d' 0)
HEX64=$(printf '%064d' 0)
HEX65=$(printf '%065d' 0)
check_status "63 characters rejected" 1 is_session_secret "$HEX63"
check_status "64 hex characters accepted" 0 is_session_secret "$HEX64"
check_status "65 characters rejected" 1 is_session_secret "$HEX65"
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
PKCS1="-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AH1hFsFkh9Ii3WJxkIiJ
line2
-----END RSA PRIVATE KEY-----"
PKCS8="-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDRndVLkklx2zfF
-----END PRIVATE KEY-----"
check_status "PKCS#1 key accepted" 0 is_jwt_private_key "$PKCS1"
check_status "PKCS#8 key rejected" 1 is_jwt_private_key "$PKCS8"
check_status "empty key rejected" 1 is_jwt_private_key ""
check_status "truncated PKCS#1 key rejected" 1 is_jwt_private_key "-----BEGIN RSA PRIVATE KEY-----
abc"

# --- write_env_file and the readers ---
ENV_DIR="$TMP/env"
mkdir -p "$ENV_DIR"
SECRET="$HEX64"
check_status "write_env_file with a key succeeds" 0 write_env_file enterprise "$SECRET" "user@example.com" "$ENV_DIR" trial "$PKCS1"
check_equal ".env mode is 600" "-rw-------" "$(ls -l "$ENV_DIR/.env" | cut -c1-10)"
check_equal "SESSION_SECRET reads back with the PEM present" "$SECRET" "$(read_env_value "$ENV_DIR/.env" SESSION_SECRET)"
check_equal "INFLUXDB_EMAIL reads back with the PEM present" "user@example.com" "$(read_env_value "$ENV_DIR/.env" INFLUXDB_EMAIL)"
check_equal "INFLUXDB_LICENSE_TYPE reads back with the PEM present" "trial" "$(read_env_value "$ENV_DIR/.env" INFLUXDB_LICENSE_TYPE)"
check_equal "JWT_PRIVATE_KEY round-trips byte for byte" "$PKCS1" "$(read_env_jwt_private_key "$ENV_DIR/.env")"
check_status "the read-back key is still a PKCS#1 key" 0 is_jwt_private_key "$(read_env_jwt_private_key "$ENV_DIR/.env")"
check_equal "JWT_PRIVATE_KEY is the last entry" 'JWT_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----' "$(grep -n 'JWT_PRIVATE_KEY=' "$ENV_DIR/.env" | cut -d: -f2-)"

check_status "write_env_file without a key succeeds" 0 write_env_file enterprise "$SECRET" "user@example.com" "$ENV_DIR" trial ""
check_file_lacks "no JWT_PRIVATE_KEY line without a key" "$ENV_DIR/.env" "JWT_PRIVATE_KEY"
check_status "read_env_jwt_private_key fails without a key" 1 read_env_jwt_private_key "$ENV_DIR/.env"
check_status "read_env_jwt_private_key fails without a file" 1 read_env_jwt_private_key "$ENV_DIR/missing"

check_status "write_env_file for Core keeps a stored key" 0 write_env_file core "$SECRET" "" "$ENV_DIR" "" "$PKCS1"
check_file_lacks "Core .env has no INFLUXDB_EMAIL" "$ENV_DIR/.env" "INFLUXDB_EMAIL"
check_file_lacks "Core .env has no INFLUXDB_LICENSE_TYPE" "$ENV_DIR/.env" "INFLUXDB_LICENSE_TYPE"
check_equal "Core .env keeps the JWT key" "$PKCS1" "$(read_env_jwt_private_key "$ENV_DIR/.env")"

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
check_file_has "embedded: port published on loopback only" "$COMPOSE" '"127.0.0.1:8181:8181"'
check_file_lacks "embedded: no Explorer service" "$COMPOSE" "influxdb3-explorer"
check_file_lacks "embedded: no Explorer session secret" "$COMPOSE" "SESSION_SECRET_KEY"
check_file_lacks "embedded: secrets not on the command line" "$COMPOSE" "webui-session-secret"
check_file_lacks "embedded: secrets not on the command line (key)" "$COMPOSE" "jwt-private-key"

COMPOSE_DIR="$TMP/compose-explorer"
mkdir -p "$COMPOSE_DIR"
generate_docker_compose_yaml enterprise "$COMPOSE_DIR" trial false
COMPOSE="$COMPOSE_DIR/docker-compose.yml"
check_file_has "explorer: Explorer service present" "$COMPOSE" "influxdb3-explorer:"
check_file_has "explorer: Explorer image" "$COMPOSE" "image: influxdata/influxdb3-ui"
check_file_has "explorer: Explorer port" "$COMPOSE" '"8888:8080"'
check_file_has "explorer: Explorer session secret" "$COMPOSE" 'SESSION_SECRET_KEY=${SESSION_SECRET}'
check_file_has "explorer: InfluxDB port published on all interfaces" "$COMPOSE" '- "8181:8181"'
check_file_lacks "explorer: no loopback publish" "$COMPOSE" "127.0.0.1"
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
if docker compose version >/dev/null 2>&1; then
    COMPOSE_DIR="$TMP/compose-embedded"
    DOCKER_IMAGE="influxdb:3.12.1-enterprise"
    write_env_file enterprise "$SECRET" "user@example.com" "$COMPOSE_DIR" trial "$PKCS1"
    RENDERED=$(cd "$COMPOSE_DIR" && docker compose config 2>&1)
    check_status "docker compose config parses the generated files" 0 sh -c 'cd "$1" && docker compose config >/dev/null 2>&1' sh "$COMPOSE_DIR"
    case "$RENDERED" in
        *"INFLUXDB3_JWT_PRIVATE_KEY: |-"*|*"-----END RSA PRIVATE KEY-----"*) pass ;;
        *) fail "docker compose config did not render the multi-line JWT key" ;;
    esac
    case "$RENDERED" in
        *"host_ip: 127.0.0.1"*) pass ;;
        *) fail "docker compose config did not render the loopback host_ip" ;;
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
printf '{\n  "DEFAULT_API_TOKEN": "apiv3_abc123"\n}\n' > "$CFG_HOME/explorer/config/config.json"
check_status "a real token is accepted" 0 extract_token_from_explorer_config "$CFG_HOME"
check_equal "a real token is printed" "apiv3_abc123" "$(extract_token_from_explorer_config "$CFG_HOME")"
check_status "a missing config fails" 1 extract_token_from_explorer_config "$TMP/nowhere"

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
