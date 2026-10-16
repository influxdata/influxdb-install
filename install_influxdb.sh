#!/bin/sh -e

################################################################################
# InfluxDB 3 Installation Script
################################################################################
#
# PURPOSE:
#   Automated setup script for InfluxDB 3 with intelligent installation method
#   selection and environment-aware configuration management. This script is
#   designed to be run for quick installation and non-production evaluation.
#
# INSTALLATION METHODS:
#   1. Docker Compose: Complete stack (InfluxDB + Explorer UI)
#      - Pins InfluxDB to the version set in this script, or to --version
#      - Auto-creates docker-compose.yml with proper networking
#      - Enterprise 3.12.0+ serves the embedded Explorer UI from the InfluxDB
#        container with user authentication (--mode=all,webui
#        --user-auth-type=basic); the browser creates the first admin.
#        Core and older Enterprise run the separate Explorer container.
#      - Manages Explorer configuration and session secrets
#      - Supports upgrades of existing Docker installations
#
#   2. Binary Installation: Direct binary download with optional startup
#      - Downloads precompiled binaries for supported architectures
#      - Extracts to user home directory (~/.influxdb)
#      - Auto-configures shell PATH environment
#      - Offers Quick Start, Custom, or Install-Only modes
#      - Enterprise 3.12.0+ starts with the embedded Explorer UI and user
#        authentication (--mode=all,webui --user-auth-type=basic); the
#        session secret and JWT signing key live under ~/.influxdb
#
# DIRECTORY STRUCTURE:
#   Shared data directory (both installation methods):
#     ~/.influxdb/
#       ├── data/                  (Database files - shared between Docker & Binary)
#       └── plugins/               (Custom plugins - shared between Docker & Binary)
#
#   Docker Compose specific:
#     ~/.influxdb/docker/
#       ├── docker-compose.yml     (Docker service definitions)
#       ├── .env                   (License email and type, session secret,
#       │                           JWT signing key for Enterprise 3.12.0+)
#       └── explorer/              (Explorer container only; not created for
#           ├── db/                 Enterprise 3.12.0+, and left in place on
#           └── config/             upgrade)
#
#   Binary specific:
#     ~/.influxdb/
#       ├── influxdb3              (Main binary)
#       ├── logs/                  (Timestamped server logs)
#       ├── webui-session-secret   (Enterprise 3.12.0+: embedded Explorer UI
#       │                           session secret, mode 600, reused on re-run)
#       └── jwt-private-key.pem    (Enterprise 3.12.0+: PKCS#1 RSA key that
#                                   signs user sign-in tokens, mode 600,
#                                   reused on re-run)
#
# REQUIREMENTS/PREREQUISITES:
#   Core Requirements:
#     - POSIX-compliant shell (sh or bash)
#     - curl (for downloading binaries and verification)
#     - tar (for extracting archives)
#     - shasum (macOS) or sha256sum (Linux) for SHA256 verification
#
#   Docker Compose Method:
#     - Docker engine must be running and responding
#     - docker and docker compose commands available
#
#   Binary Method:
#     - Supported OS: macOS (ARM64 only), Linux (x86_64 or ARM64)
#     - Port availability (default 8181, auto-adjusts if in use)
#     - openssl or ssh-keygen (Enterprise 3.12.0+, to generate the JWT
#       signing key on the first run)
#
# EXISTING INSTALLATION HANDLING:
#   Docker Compose:
#     - Detects existing docker-compose.yml at ~/.influxdb/docker/
#     - Automatically upgrades in-place when detected
#     - Reuses the license email and type, the session secret, and the JWT
#       signing key from .env, so a re-run does not sign users out
#     - Pulls the selected version and restarts containers with health checks
#     - Preserves all data in bind-mounted directories
#
#   Binary:
#     - Overwrites any existing binary at ~/.influxdb/influxdb3
#     - Preserves data directory (~/.influxdb/data) automatically
#     - User can run script repeatedly to upgrade to latest version
#     - Reuses the Explorer session secret and JWT signing key, so a re-run
#       does not sign users out
#
# CONFIGURATION OPTIONS:
#   Command Line Arguments:
#     [enterprise]        Install Enterprise edition (default: Core)
#     --version VERSION   Specify the InfluxDB3 version (default: the version set below)
#
#   Interactive Prompts (Binary Installation):
#     Installation Type:  Docker Compose or Binary
#     Startup Mode:       Quick Start, Custom, or Skip
#     Node ID:            Identifier for this server instance
#     Cluster ID:         (Enterprise only) Cluster identifier
#     Storage Type:       File, S3, Azure, GCS, or Memory
#     Cloud Credentials:  (If object storage selected)
#     License Type:       (Enterprise only) Trial or Home
#     License Email:      (Enterprise only) Email for activation
#
#   Docker Compose Specific:
#     Port Selection:     Automatic via find_next_available_port()
#     Session Secret:     64 hex characters from /dev/urandom; reused from .env on re-run
#     InfluxDB Port:      Default 8181 (mapped to container 8181); the embedded
#                         Explorer UI is served on this port
#     Explorer Port:      Default 8888 (mapped to container 8080); Explorer
#                         container only
#     Container Restart:  unless-stopped policy
#     License Type:       (Enterprise only) Passed as INFLUXDB3_ENTERPRISE_LICENSE_TYPE
#                         from .env; omitted when unknown (older .env)
#     JWT Signing Key:    (Enterprise 3.12.0+) 2048-bit PKCS#1 RSA key, generated
#                         with the image's openssl, stored as a quoted multi-line
#                         JWT_PRIVATE_KEY in .env, passed as INFLUXDB3_JWT_PRIVATE_KEY
#
# EXIT POINTS AND CONDITIONS:
#   Successful Exits (exit 0):
#     - Docker Compose: After successful deployment with access points shown
#     - Docker Upgrade: After successful image pull and container restart
#     - Binary: After showing "Next Steps" information
#     - Skip Startup: After installation without starting service
#
#   Error Exits (exit 1):
#     - Unsupported OS/Architecture (Intel Mac, Windows, etc.)
#     - Docker not running or unavailable (Docker Compose path)
#     - Requested version has no Docker image
#     - Failed image pulls or docker compose commands
#     - Requested version not found at the release URL (checked before download)
#     - Failed binary download, signature verification, or extraction
#     - Invalid SHA256 checksum on downloaded binary
#     - Container startup timeout (30 seconds for Core, 90 for Enterprise, 60 for Explorer)
#     - Port allocation failure or port range exhausted
#
# SPECIAL BEHAVIORS:
#   Binary Download:
#     - URL format: https://dl.influxdata.com/influxdb/releases/
#       influxdb3-{edition_tag}-{version}_{artifact}.tar.gz
#     - Downloads corresponding .sha256 file for verification
#     - Validates checksums before extraction
#     - Automatically adds installation path to shell rc file
#
#   Binary Embedded UI (Enterprise 3.12.0+):
#     - Every startup choice, including Skip, loads or creates the session
#       secret and the JWT signing key so the displayed serve command is real
#     - A malformed secret or key file is replaced with a warning; a failed
#       generation stops the script
#     - Both reach the server through INFLUXDB3_WEBUI_SESSION_SECRET and
#       INFLUXDB3_JWT_PRIVATE_KEY, not flags, so they are absent from the
#       process list; displayed commands show them as "$(cat <file>)"
#     - The script creates no users and no tokens; the browser's setup page
#       creates the first admin and shows the operator token once
#
#   Docker Compose:
#     - Creates internal network (influxdb-network) for service communication
#     - Configures the Explorer container to reach InfluxDB by container name
#     - Embedded UI (Enterprise 3.12.0+): passes --mode=all,webui,
#       --user-auth-type=basic, and --jwt-key-id=install-script; the session
#       secret and JWT signing key reach the server through the environment.
#       The script creates no users and no tokens; the browser's setup page
#       creates the first admin and shows the operator token once.
#     - Opens Explorer UI in default browser upon successful startup
#     - Filters verbose docker compose output for cleaner display
#
#   Health Checking:
#     - InfluxDB (Docker): Waits for "startup time:" in container logs
#     - InfluxDB (Binary): Polls /health until it answers; any HTTP response,
#       including 401 when the server requires auth, means the listener is
#       up, and the UI is loaded before the listener starts
#     - Explorer container: Polls /api/health endpoint for "ok/status/healthy"
#     - Embedded UI: One request on / after the InfluxDB check; the result only
#       selects the summary wording and whether the browser opens
#
# SHELL EXECUTION CONTEXT:
#   - Runs with `sh -e` (error exit on command failure)
#   - Uses POSIX-compatible syntax for maximum portability
#   - Disables shellcheck SC2059 for printf variable interpolation
#   - Exports INFLUXDB3_SERVE_INVOCATION_METHOD for telemetry tracking
#
################################################################################

# ==============================================================================
# SECTION 1: SCRIPT CONFIGURATION
# ==============================================================================

export LC_ALL=C

readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly BOLDGREEN='\033[1;32m'
readonly DIM='\033[2m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

# No diagnostics for: 'printf "...${FOO}"'
# shellcheck disable=SC2059

# Docker Compose Constants
INFLUXDB_PORT=8181  # Can be changed if port is in use
EXPLORER_PORT=8888  # Can be changed if port is in use
readonly EXPLORER_IMAGE="influxdata/influxdb3-ui"
readonly MANUAL_TOKEN_MSG="MANUAL_TOKEN_CREATION_REQUIRED"

ARCHITECTURE=$(uname -m)
ARTIFACT=""
OS=""
INSTALL_LOC=~/.influxdb
BINARY_NAME="influxdb3"
PORT=8181
# Script-owned secret files for the embedded Explorer UI with user auth
# (Enterprise 3.12.0+ binary), mode 600, reused on every run
WEBUI_SECRET_FILE="$INSTALL_LOC/webui-session-secret"
JWT_KEY_FILE="$INSTALL_LOC/jwt-private-key.pem"

# Seconds to wait for the server to come up; shared by the binary and Docker paths
readonly STARTUP_TIMEOUT_CORE=30
readonly STARTUP_TIMEOUT_ENTERPRISE=90

# Set the default (latest) version here. Users may specify a version using the
# --version arg (handled below)
INFLUXDB_VERSION_FLAG_SET="0"
INFLUXDB_OSS_VERSION="3.12.1"
INFLUXDB_ENT_VERSION=3.12.1

EDITION="Core"
EDITION_TAG="core"
INFLUXDB_VERSION="${INFLUXDB_OSS_VERSION}"

# ==============================================================================
# SECTION 2: COMMAND LINE ARGUMENT PARSING
# ==============================================================================

print_usage() {
    printf "Usage: %s [enterprise] [--version VERSION]\n" "$0"
    printf "  enterprise: Install the Enterprise edition (optional)\n"
    printf "  --version VERSION: Specify the InfluxDB version (default: Core %s, Enterprise %s)\n" "$INFLUXDB_OSS_VERSION" "$INFLUXDB_ENT_VERSION"
}

NEWLINE='
'

is_valid_version() {
    case "$1" in
        *"${NEWLINE}"*) return 1 ;;
    esac
    printf '%s' "$1" | grep -Eq '^3\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                printf "Error: --version requires a value (e.g. --version %s)\n\n" "$INFLUXDB_OSS_VERSION" >&2
                print_usage >&2
                exit 1
            fi
            if ! is_valid_version "$2"; then
                printf "Error: invalid version '%s'. Expected a final release in the form 3.Y.Z (e.g. 3.12.0)\n\n" "$2" >&2
                print_usage >&2
                exit 1
            fi
            INFLUXDB_VERSION="$2"
            INFLUXDB_VERSION_FLAG_SET=1
            shift 2
            ;;
        enterprise)
            EDITION="Enterprise"
            EDITION_TAG="enterprise"
            if [ "${INFLUXDB_VERSION_FLAG_SET}" = "0" ]; then
                INFLUXDB_VERSION="${INFLUXDB_ENT_VERSION}"
            fi
            shift 1
            ;;
        *)
            print_usage >&2
            exit 1
            ;;
    esac
done

# ==============================================================================
# SECTION 3: SYSTEM DETECTION
# ==============================================================================

case "$(uname -s)" in
    Linux*)     OS="Linux";;
    Darwin*)    OS="Darwin";;
    *)         OS="UNKNOWN";;
esac

if [ "${OS}" = "Linux" ]; then
    # ldd is a shell script but on some systems (eg Ubuntu) security hardening
    # prevents it from running when invoked directly. Since we only want to
    # use '--verbose', find the path to ldd, then invoke under sh to bypass ldd
    # hardening.
    if [ "${ARCHITECTURE}" = "x86_64" ] || [ "${ARCHITECTURE}" = "amd64" ]; then
        ARTIFACT="linux_amd64"
    elif [ "${ARCHITECTURE}" = "aarch64" ] || [ "${ARCHITECTURE}" = "arm64" ]; then
        ARTIFACT="linux_arm64"
    fi
elif [ "${OS}" = "Darwin" ]; then
    if [ "${ARCHITECTURE}" = "x86_64" ]; then
        printf "Intel Mac support is coming soon!\n"
        printf "Visit our public Discord at \033[4;94mhttps://discord.gg/az4jPm8x${NC} for additional guidance.\n"
        printf "View alternative binaries on our Getting Started guide at \033[4;94mhttps://docs.influxdata.com/influxdb3/${EDITION_TAG}/${NC}.\n"
        exit 1
    else
        ARTIFACT="darwin_arm64"
    fi
fi

# Exit if unsupported system
[ -n "${ARTIFACT}" ] || {
    printf "Unfortunately this script doesn't support your '${OS}' | '${ARCHITECTURE}' setup, or was unable to identify it correctly.\n"
    printf "Visit our public Discord at \033[4;94mhttps://discord.gg/az4jPm8x${NC} for additional guidance.\n"
    printf "View alternative binaries on our Getting Started guide at \033[4;94mhttps://docs.influxdata.com/influxdb3/${EDITION_TAG}/${NC}.\n"
    exit 1
}

URL="https://dl.influxdata.com/influxdb/releases/influxdb3-${EDITION_TAG}-${INFLUXDB_VERSION}_${ARTIFACT}.tar.gz"

# Docker image, pinned to the selected version (never the floating 3-<edition> tag).
DOCKER_IMAGE="influxdb:${INFLUXDB_VERSION}-${EDITION_TAG}"



# ==============================================================================
# SECTION 4: GENERAL UTILITY FUNCTIONS
# ==============================================================================
# Cross-cutting utilities used by multiple installation methods

# --- Port Management ---

# Find next available port starting from given port
# Parameters: $1 - starting_port (e.g., 8181)
# Returns: Available port number (echoes to stdout)
# Exits: 1 if port range exhausted (>32767)
find_next_available_port() {
    current_port="$1"

    lsof_exec=$(command -v lsof)
    if [ -z "$lsof_exec" ]; then
        echo "$current_port"
        return 0
    fi

    while "$lsof_exec" -i:"$current_port" -t >/dev/null 2>&1; do
        printf "├─${DIM} Port %s is in use. Finding new port.${NC}\n" "$current_port" >&2
        current_port=$((current_port + 1))
        if [ "$current_port" -gt 32767 ]; then
            printf "└─${RED} Could not find an available port. Aborting.${NC}\n" >&2
            exit 1
        fi
    done

    echo "$current_port"
}

# --- Release Availability ---

check_release_url() {
    release_url="$1"
    printf "${BOLD}Checking that InfluxDB 3 %s %s is available for %s${NC}\n" "$EDITION" "$INFLUXDB_VERSION" "$ARTIFACT"
    printf "└─${DIM} curl -sIL --max-time 30 -o /dev/null -w '%%{http_code}' '%s'" "$release_url"
    http_code=$(curl -sIL --max-time 30 -o /dev/null -w '%{http_code}' "$release_url" 2>/dev/null) || http_code="000"
    case "$http_code" in
        200)
            printf " (OK: HTTP 200)${NC}\n"
            ;;
        404)
            printf " (Error: HTTP 404)${NC}\n"
            printf "\n${RED}Error:${NC} InfluxDB 3 %s %s was not found for %s.\n" "$EDITION" "$INFLUXDB_VERSION" "$ARTIFACT" >&2
            printf "No release at '%s'.\n" "$release_url" >&2
            if [ "${INFLUXDB_VERSION_FLAG_SET}" = "1" ]; then
                if [ "$EDITION" = "Enterprise" ]; then
                    default_version="$INFLUXDB_ENT_VERSION"
                else
                    default_version="$INFLUXDB_OSS_VERSION"
                fi
                printf "Check the version passed with --version, or omit it to install the default (%s).\n" "$default_version" >&2
            else
                printf "The default version is not published. Pass --version to choose another release, or check for a newer copy of this script.\n" >&2
            fi
            exit 1
            ;;
        *)
            # Only 404 is a definitive answer. Anything else may be a proxy or
            # CDN rejecting HEAD, so continue and let the download decide.
            if [ "$http_code" = "000" ]; then
                status="no response"
            else
                status="HTTP $http_code"
            fi
            printf " (Warning: %s)${NC}\n" "$status"
            printf "${YELLOW}Warning:${NC} Could not confirm that '%s' is available (%s).\n" "$release_url" "$status"
            printf "Continuing; the download will report any problem.\n"
            ;;
    esac
}

# Download a URL to a file; exit on HTTP or network error. No overall
# timeout: abort only on a stalled connection. HTTP/1.1 because macOS
# curl 8.7.1 does not retry 5xx over HTTP/2 with -f.
download_file() {
    dl_url="$1"
    dl_dest="$2"
    dl_opts="-sSfL --http1.1 --connect-timeout 30 --speed-limit 1024 --speed-time 60 --retry 3"
    printf "└─${DIM} curl %s '%s' -o '%s'${NC}\n" "$dl_opts" "$dl_url" "$dl_dest"
    # shellcheck disable=SC2086  # intentional word-split
    if ! dl_err=$(curl $dl_opts "$dl_url" -o "$dl_dest" 2>&1); then
        printf "\n${RED}Error:${NC} Failed to download '%s'.\n" "$dl_url" >&2
        printf "%s\n" "$dl_err" >&2
        printf "Check your network or proxy, or retry later. If the problem persists, pass --version to choose another release.\n" >&2
        # Best-effort cleanup; must not mask the error above.
        [ -f "$dl_dest" ] && rm -f -- "$dl_dest" 2>/dev/null || :
        exit 1
    fi
}

# --- Version Capabilities ---

# Returns 0 if dotted version $1 is numerically $2 or later
version_at_least() {
    have="$1"
    want="$2"
    while [ -n "$have" ] || [ -n "$want" ]; do
        have_field="${have%%.*}"
        want_field="${want%%.*}"
        if [ "${have_field:-0}" -gt "${want_field:-0}" ]; then
            return 0
        fi
        if [ "${have_field:-0}" -lt "${want_field:-0}" ]; then
            return 1
        fi
        case "$have" in *.*) have="${have#*.}" ;; *) have="" ;; esac
        case "$want" in *.*) want="${want#*.}" ;; *) want="" ;; esac
    done
    return 0
}

# Returns 0 if EDITION and INFLUXDB_VERSION serve the embedded Explorer UI
# with user authentication (Enterprise 3.12.0+). Core has neither.
has_embedded_ui() {
    if [ "$EDITION" != "Enterprise" ]; then
        return 1
    fi
    version_at_least "$INFLUXDB_VERSION" "3.12.0"
}

# --- Browser Integration ---

# Utility function to open URL in browser
open_browser_url() {
    URL="$1"
    if command -v open >/dev/null 2>&1; then
        open "$URL" >/dev/null 2>&1 &
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$URL" >/dev/null 2>&1 &
    elif command -v start >/dev/null 2>&1; then
        start "$URL" >/dev/null 2>&1 &
    fi
}

# --- Security Utilities ---

# Exits 0 when $1 is 64 hex characters
is_session_secret() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in
        *[!0-9a-fA-F]*) return 1 ;;
    esac
    return 0
}

# Prints 32 random bytes as 64 hex characters
# Returns: 1 when generation fails (sh -e ignores a failed pipeline stage)
generate_session_secret() {
    GENERATED_SECRET=$(head -c 32 /dev/urandom | od -An -v -tx1 | tr -d ' \n')
    is_session_secret "$GENERATED_SECRET" || return 1
    printf '%s\n' "$GENERATED_SECRET"
}

# --- Startup Messages ---
# Shared by perform_server_health_check (binary) and wait_for_container_ready
# (Docker) so both paths report the same thing while the server comes up.

# Shown once, 10 seconds into startup, when this run requested a new license
print_license_verification_notice() {
    printf "├─${YELLOW} License activation requires email verification${NC}\n"
    printf "├─${BOLD} → Check your inbox and click the verification link${NC}\n"
}

# Shown every 15 seconds while a new license is pending
# Parameters:
#   $1 - seconds waited so far
#   $2 - timeout in seconds
print_license_verification_progress() {
    printf "├─${DIM} Waiting for license verification (%s/%ss)${NC}\n" "$1" "$2"
}

# Shown when the server has not come up within the timeout
# Parameters:
#   $1 - timeout in seconds
#   $2 - "true" for Enterprise
#   $3 - non-empty when this run requested a new license
#   $4 - server port
#   $5 - where to find the logs (a file path or a docker logs command)
print_startup_timeout_error() {
    if [ "$2" = "true" ]; then
        printf "├─${BOLD} Error: InfluxDB Enterprise failed to start within %s seconds${NC}\n\n" "$1"
        if [ -n "$3" ]; then
            printf "   ├─${YELLOW} Check your email for license verification${NC} ${BOLD}(REQUIRED)${NC}\n"
            printf "   │  ${BOLD}→ Click the verification link in your inbox${NC}\n"
        fi
        printf "   ├─ Check for network connectivity issues\n"
        printf "   ├─ Check for port %s conflicts\n" "$4"
        printf "   └─ Check the logs: %s\n" "$5"
    else
        printf "└─${BOLD} Error: InfluxDB failed to start; check permissions or other potential issues.${NC}\n"
        printf "   Logs: %s\n" "$5"
    fi
}

# Exits 0 when $1 looks like a PKCS#1 RSA private key, the only form the
# server accepts for signing user sign-in tokens (PKCS#8 is rejected)
is_jwt_private_key() {
    case "$1" in
        "-----BEGIN RSA PRIVATE KEY-----"*"-----END RSA PRIVATE KEY-----") return 0 ;;
    esac
    return 1
}

# Prints a 2048-bit PKCS#1 RSA key using "$@" as the openssl command.
# LibreSSL (macOS /usr/bin/openssl) writes PKCS#1 by default and rejects
# -traditional; OpenSSL 3 and later write PKCS#8 by default and need it.
# Returns: 1 when neither form yields a PKCS#1 key
openssl_pkcs1_key() {
    GENERATED_KEY=$("$@" genrsa 2048 2>/dev/null) || GENERATED_KEY=""
    if ! is_jwt_private_key "$GENERATED_KEY"; then
        GENERATED_KEY=$("$@" genrsa -traditional 2048 2>/dev/null) || GENERATED_KEY=""
    fi
    is_jwt_private_key "$GENERATED_KEY" || return 1
    printf '%s\n' "$GENERATED_KEY"
}

# Prints a new JWT signing key, trying in order: openssl inside the Docker
# image $1 (when given, so the host needs nothing), openssl on the host,
# and ssh-keygen on the host.
# Parameters:
#   $1 - Docker image whose openssl to use first, or empty
# Returns: 1 when no generator is available
generate_jwt_private_key() {
    if [ -n "${1:-}" ]; then
        openssl_pkcs1_key docker run --rm --entrypoint openssl "$1" && return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl_pkcs1_key openssl && return 0
    fi
    if command -v ssh-keygen >/dev/null 2>&1; then
        KEYGEN_DIR=$(mktemp -d 2>/dev/null) || return 1
        GENERATED_KEY=""
        if ssh-keygen -q -m PEM -t rsa -b 2048 -N '' -f "$KEYGEN_DIR/key" </dev/null >/dev/null 2>&1; then
            GENERATED_KEY=$(cat "$KEYGEN_DIR/key" 2>/dev/null) || GENERATED_KEY=""
        fi
        rm -rf "$KEYGEN_DIR"
        if is_jwt_private_key "$GENERATED_KEY"; then
            printf '%s\n' "$GENERATED_KEY"
            return 0
        fi
    fi
    return 1
}

# ==============================================================================
# SECTION 5: DOCKER COMPOSE UTILITIES
# ==============================================================================
# Docker-specific operations and helpers

# --- Docker Validation ---

# Function to check if Docker is available and running
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        return 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# --- Image Availability ---

# True when registry or daemon output says the requested tag does not exist.
# Shared by the pre-check and the pull error handler so the two never drift.
# Covers `docker manifest inspect` ("no such manifest"), older daemons
# ("manifest unknown"), and the containerd image store
# ('failed to resolve reference "...": not found'). The last form is anchored
# so unrelated "not found" errors, such as a missing credential helper, do not match.
# Parameters: $1 - captured command output
is_missing_image_error() {
    echo "$1" | grep -qi "no such manifest\|manifest unknown\|failed to resolve reference .*: not found"
}

# Check that an image tag exists on the registry before any setup work.
# `docker manifest inspect` queries the registry without downloading layers.
# It runs on the CLI host and bypasses daemon mirrors and proxies, so only a
# definitive "tag missing" answer is treated as fatal. Any other failure is a
# warning and the later pull, which goes through the daemon, decides.
# Uses the globals DOCKER_IMAGE, EDITION, INFLUXDB_VERSION, and INFLUXDB_VERSION_FLAG_SET.
# Returns: 1 if the registry reports the tag missing, 0 otherwise
check_docker_image() {
    printf "├─ Checking that %s is available..." "$DOCKER_IMAGE"

    INSPECT_OUTPUT=$(docker manifest inspect "$DOCKER_IMAGE" 2>&1) && {
        printf "SUCCESS\n"
        return 0
    }

    if is_missing_image_error "$INSPECT_OUTPUT"; then
        printf "${RED}FAILED${NC}\n"
        printf "\n${RED}Error:${NC} InfluxDB 3 %s %s was not found on Docker Hub.\n" "$EDITION" "$INFLUXDB_VERSION" >&2
        printf "No image tagged '%s'.\n" "$DOCKER_IMAGE" >&2
        if [ "${INFLUXDB_VERSION_FLAG_SET}" = "1" ]; then
            printf "Check the version passed with --version.\n\n" >&2
        else
            printf "This script defaults to %s, which has no Docker image yet. Pass --version to install another release.\n\n" "$INFLUXDB_VERSION" >&2
        fi
        return 1
    fi

    printf "${YELLOW}SKIPPED${NC}\n"
    printf "│  ${YELLOW}Warning: Could not check '%s' on Docker Hub${NC}\n" "$DOCKER_IMAGE"
    printf "│  %s\n" "$INSPECT_OUTPUT"
    printf "│  Continuing; the image pull will report any problem\n"
    return 0
}

# --- Image Management ---

# Pull Docker Compose image with configurable error handling
# Parameters:
#   $1 - service_name: Docker Compose service name to pull
#   $2 - display_name: Human-readable name for progress messages
#   $3 - is_fatal: "true" if failure should abort, "false" to continue (default: false)
# Returns: 0 on success or non-fatal failure, 1 on fatal failure
pull_docker_image() {
    service_name="$1"
    display_name="$2"
    is_fatal="${3:-false}"

    printf "├─ Pulling %s image..." "$display_name"

    # Capture error output
    PULL_OUTPUT=$(docker compose pull "$service_name" 2>&1)
    PULL_EXIT_CODE=$?

    if [ $PULL_EXIT_CODE -eq 0 ]; then
        printf "SUCCESS\n"
        return 0
    else
        if [ "$is_fatal" = "true" ]; then
            printf "${RED}FAILED${NC}\n"
            printf "└─ ${RED}Error: Failed to pull %s image${NC}\n" "$display_name"

            # Display actual error with context
            printf "\n${BOLD}Error details:${NC}\n"
            printf "%s\n\n" "$PULL_OUTPUT"

            # Provide specific troubleshooting based on error content
            printf "${BOLD}Possible causes:${NC}\n"
            if is_missing_image_error "$PULL_OUTPUT"; then
                printf "  • The image tag does not exist on Docker Hub\n"
                if [ "${INFLUXDB_VERSION_FLAG_SET}" = "1" ]; then
                    printf "  • Check the version passed with --version\n"
                else
                    printf "  • This script defaults to %s, which has no Docker image yet; pass --version to install another release\n" "$INFLUXDB_VERSION"
                fi
            elif echo "$PULL_OUTPUT" | grep -qi "denied\|unauthorized"; then
                printf "  • Docker Hub authentication required or rate limited\n"
                printf "  • Try: docker login\n"
            elif echo "$PULL_OUTPUT" | grep -qi "network\|timeout\|connection"; then
                printf "  • Network connectivity issue\n"
                printf "  • Check your internet connection\n"
            elif echo "$PULL_OUTPUT" | grep -qi "daemon"; then
                printf "  • Docker daemon may not be responding\n"
                printf "  • Try: docker info\n"
            elif echo "$PULL_OUTPUT" | grep -qi "yaml\|control characters"; then
                printf "  • Invalid YAML syntax in docker-compose.yml\n"
                printf "  • Inspect file: cat %s/docker-compose.yml\n" "$DOCKER_DIR"
            else
                printf "  • Check Docker daemon status: docker info\n"
                printf "  • Check internet connection\n"
                printf "  • Check Docker Hub access\n"
            fi
            printf "\n"
            return 1
        else
            printf "${YELLOW}FAILED${NC}\n"
            printf "│  ${YELLOW}Warning: %s will not be available${NC}\n" "$display_name"
            printf "│  You can run this script again later to install it\n"
            return 0
        fi
    fi
}

# --- Output Formatting ---

# Utility function to filter Docker Compose output
filter_docker_output() {
    grep -v "version.*obsolete" | \
    grep -v "Creating$" | \
    grep -v "Created$" | \
    grep -v "Starting$" | \
    grep -v "Started$" | \
    grep -v "Running$" \
    || true
}

# --- Filesystem Setup ---

# Utility function to create docker directories with permissions
# Parameters:
#   $1 - docker directory
#   $2 - "true" when the server embeds the Explorer UI, so no Explorer
#        container runs and its directories are not needed. An existing
#        explorer/ directory from an older install is left in place.
create_docker_directories() {
    DOCKER_DIR="$1"
    EMBEDDED_UI="${2:-false}"

    # Create shared data directories (used by both Docker and binary)
    mkdir -p "$HOME/.influxdb/data"
    mkdir -p "$HOME/.influxdb/plugins"

    # Compose file and .env live here
    mkdir -p "$DOCKER_DIR"

    if [ "$EMBEDDED_UI" = "true" ]; then
        return 0
    fi

    # Explorer container directories
    mkdir -p "$DOCKER_DIR/explorer/db"
    mkdir -p "$DOCKER_DIR/explorer/config"

    chmod 700 "$DOCKER_DIR/explorer/db" 2>/dev/null || true
    chmod 750 "$DOCKER_DIR/explorer/config" 2>/dev/null || true
}

# --- Health Checks ---

# Utility function to wait for the InfluxDB container to be ready.
# Mirrors perform_server_health_check on the binary path: same timeouts,
# license verification notices, and timeout messages.
# Parameters:
#   $1 - container name
#   $2 - log line that marks the server as ready
#   $3 - timeout in seconds (default STARTUP_TIMEOUT_CORE)
#   $4 - edition: "core" or "enterprise"
#   $5 - non-empty when this run requested a new license (shows the email notice)
wait_for_container_ready() {
    CONTAINER_NAME="$1"
    READY_MESSAGE="$2"
    TIMEOUT="${3:-$STARTUP_TIMEOUT_CORE}"
    EDITION_TYPE="${4:-}"
    NEW_LICENSE="${5:-}"
    if [ "$EDITION_TYPE" = "enterprise" ]; then
        IS_ENTERPRISE=true
    else
        IS_ENTERPRISE=false
    fi

    # Progress dots run until the first license message takes over the line
    printf "├─ Starting InfluxDB"
    DOTS_OPEN=true
    EMAIL_MESSAGE_SHOWN=false

    for i in $(seq 1 "$TIMEOUT"); do
        if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "$READY_MESSAGE"; then
            if [ "$DOTS_OPEN" = "true" ]; then printf "${NC}\n"; fi
            return 0
        fi

        if ! docker ps | grep -q "$CONTAINER_NAME"; then
            if [ "$DOTS_OPEN" = "true" ]; then printf "${NC}\n"; fi
            printf "├─${RED} Error: InfluxDB container stopped unexpectedly${NC}\n"
            docker logs --tail 20 "$CONTAINER_NAME"
            return 1
        fi

        # Show email verification message after 10 seconds for a new license
        if [ "$IS_ENTERPRISE" = "true" ] && [ -n "$NEW_LICENSE" ] && [ "$i" -eq 10 ] && [ "$EMAIL_MESSAGE_SHOWN" = "false" ]; then
            printf "${NC}\n"
            DOTS_OPEN=false
            print_license_verification_notice
            EMAIL_MESSAGE_SHOWN=true
        fi

        # Show progress updates every 15 seconds after initial grace period
        if [ "$IS_ENTERPRISE" = "true" ] && [ -n "$NEW_LICENSE" ] && [ "$i" -gt 5 ] && [ $((i % 15)) -eq 0 ]; then
            print_license_verification_progress "$i" "$TIMEOUT"
        fi

        if [ "$DOTS_OPEN" = "true" ]; then printf "."; fi
        sleep 1
    done

    if [ "$DOTS_OPEN" = "true" ]; then printf "${NC}\n"; fi
    print_startup_timeout_error "$TIMEOUT" "$IS_ENTERPRISE" "$NEW_LICENSE" "$INFLUXDB_PORT" "docker logs $CONTAINER_NAME"

    # Unlike the binary path, which stops its background process, the container
    # is left running: once the license is verified it finishes starting on its own
    if [ -n "$NEW_LICENSE" ] && docker ps | grep -q "$CONTAINER_NAME"; then
        printf "\n"
        printf "The %s container is still running and will finish starting once the license is verified.\n" "$CONTAINER_NAME"
        if [ "${USE_EMBEDDED_UI:-false}" = true ]; then
            printf "Re-run this script afterwards to finish setting up Explorer.\n"
        else
            printf "Re-run this script afterwards to finish setting up the operator token and Explorer.\n"
        fi
    fi
    return 1
}

# Utility function to wait for Explorer to be fully ready
wait_for_explorer_ready() {
    TIMEOUT="${1:-60}"

    printf "└─ Starting Explorer"
    ELAPSED=0

    while [ $ELAPSED -lt $TIMEOUT ]; do
        if curl -s http://localhost:$EXPLORER_PORT >/dev/null 2>&1; then
            API_RESPONSE=$(curl -s http://localhost:$EXPLORER_PORT/api/health 2>&1)
            if echo "$API_RESPONSE" | grep -q "ok\|status\|healthy" 2>/dev/null; then
                printf "${NC}\n"
                return 0
            fi
        fi

        printf "."
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
    printf "${NC}\n"
    return 1
}

# --- Token Management ---

# Utility function to create operator token via API
create_operator_token() {
    CONTAINER_NAME="$1"

    # Try API with retries
    MAX_RETRIES=3
    RETRY=0
    TOKEN=""

    while [ $RETRY -lt $MAX_RETRIES ] && [ -z "$TOKEN" ]; do
        TOKEN_RESPONSE=$(curl -s -w "\n%{http_code}" -m 5 -X POST http://localhost:$INFLUXDB_PORT/api/v3/configure/token/admin 2>&1)

        # Extract HTTP status code (last line)
        HTTP_CODE=$(echo "$TOKEN_RESPONSE" | tail -n1)
        # Extract response body (all but last line)
        RESPONSE_BODY=$(echo "$TOKEN_RESPONSE" | sed '$d')

        # Check for 409 conflict
        if [ "$HTTP_CODE" = "409" ]; then
            echo "TOKEN_ALREADY_EXISTS"
            return 2
        fi

        # Try to extract token from response
        TOKEN=$(echo "$RESPONSE_BODY" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

        if [ -z "$TOKEN" ] && [ $RETRY -lt $((MAX_RETRIES - 1)) ]; then
            sleep 2
            RETRY=$((RETRY + 1))
        else
            break
        fi
    done

    # Return token or manual creation message
    if [ -n "$TOKEN" ]; then
        echo "$TOKEN"
        return 0
    else
        echo "$MANUAL_TOKEN_MSG"
        return 1
    fi
}

# --- Configuration Generation ---

# Function to generate Docker Compose YAML
# Parameters:
#   $1 - edition: "core" or "enterprise"
#   $2 - docker directory
#   $3 - license type ("trial", "home", or empty when unknown; Enterprise only)
#   $4 - "true" when the server embeds the Explorer UI (Enterprise 3.12.0+).
#        The server then runs with --mode=all,webui and basic user auth, the
#        session secret and JWT signing key come from its environment, and
#        the compose file has no Explorer service.
generate_docker_compose_yaml() {
    EDITION_TYPE="$1"
    DOCKER_DIR="$2"
    COMPOSE_LICENSE_TYPE="${3:-}"
    EMBEDDED_UI="${4:-false}"

    USER_UID=$(id -u)
    USER_GID=$(id -g)

    # Determine edition-specific values
    if [ "$EDITION_TYPE" = "enterprise" ]; then
        SERVICE_NAME="influxdb3-enterprise"
        EXTRA_ARGS="      - --cluster-id=cluster0"
        ENV_SECTION="    environment:
      - INFLUXDB3_ENTERPRISE_LICENSE_EMAIL=\${INFLUXDB_EMAIL}"
        # Only when known: the server exits on an empty --license-type, and
        # compose substitutes an empty string for a key missing from .env
        if [ -n "$COMPOSE_LICENSE_TYPE" ]; then
            ENV_SECTION="${ENV_SECTION}
      - INFLUXDB3_ENTERPRISE_LICENSE_TYPE=\${INFLUXDB_LICENSE_TYPE}"
        fi
    else
        SERVICE_NAME="influxdb3-core"
        EXTRA_ARGS=""
        ENV_SECTION=""
    fi

    if [ "$EMBEDDED_UI" = "true" ]; then
        # `all` does not include `webui`, so both are listed. The secret and
        # the signing key are passed through the environment so they do not
        # appear in the container's command line. The key id is any fixed
        # string; it only labels the key inside issued tokens.
        if [ -n "$EXTRA_ARGS" ]; then
            EXTRA_ARGS="${EXTRA_ARGS}
"
        fi
        EXTRA_ARGS="${EXTRA_ARGS}      - --mode=all,webui
      - --user-auth-type=basic
      - --jwt-key-id=install-script"
        if [ -z "$ENV_SECTION" ]; then
            ENV_SECTION="    environment:"
        fi
        ENV_SECTION="${ENV_SECTION}
      - INFLUXDB3_WEBUI_SESSION_SECRET=\${SESSION_SECRET}
      - INFLUXDB3_JWT_PRIVATE_KEY=\${JWT_PRIVATE_KEY}"
        EXPLORER_SERVICE=""
    else
        EXPLORER_SERVICE="
  influxdb3-explorer:
    image: ${EXPLORER_IMAGE}
    container_name: influxdb3-explorer
    command: [\"--mode=admin\"]
    ports:
      - \"${EXPLORER_PORT}:8080\"
    volumes:
      - ./explorer/db:/db:rw
      - ./explorer/config:/app-root/config:ro
    environment:
      - SESSION_SECRET_KEY=\${SESSION_SECRET}
    restart: unless-stopped
    depends_on:
      - ${SERVICE_NAME}
    networks:
      - influxdb-network
"
    fi

    cat > "$DOCKER_DIR/docker-compose.yml" << COMPOSE_EOF
services:
  ${SERVICE_NAME}:
    image: ${DOCKER_IMAGE}
    container_name: ${SERVICE_NAME}
    user: "${USER_UID}:${USER_GID}"
    ports:
      - "${INFLUXDB_PORT}:8181"
    command:
      - influxdb3
      - serve
      - --node-id=node0${EXTRA_ARGS:+
${EXTRA_ARGS}}
      - --object-store=file
      - --data-dir=/var/lib/influxdb3/data
      - --plugin-dir=/var/lib/influxdb3/plugins${ENV_SECTION:+
${ENV_SECTION}}
    volumes:
      - ~/.influxdb/data:/var/lib/influxdb3/data
      - ~/.influxdb/plugins:/var/lib/influxdb3/plugins
    restart: unless-stopped
    networks:
      - influxdb-network
${EXPLORER_SERVICE}
networks:
  influxdb-network:
    driver: bridge
COMPOSE_EOF
}

# Function to write the Docker .env file
# Parameters:
#   $1 - edition: "core" or "enterprise"
#   $2 - session secret
#   $3 - license email (Enterprise only)
#   $4 - docker directory
#   $5 - license type, or empty when unknown (Enterprise only)
#   $6 - JWT signing key (PEM), or empty when none is known yet (embedded UI only)
# Returns: 0 on success, 1 when the file cannot be written
write_env_file() {
    EDITION_TYPE="$1"
    SESSION_SECRET="$2"
    LICENSE_EMAIL="$3"
    DOCKER_DIR="$4"
    ENV_LICENSE_TYPE="${5:-}"
    ENV_JWT_KEY="${6:-}"

    ENV_CONTENT="SESSION_SECRET=${SESSION_SECRET}"
    if [ "$EDITION_TYPE" = "enterprise" ]; then
        if [ -n "$ENV_LICENSE_TYPE" ]; then
            ENV_CONTENT="INFLUXDB_LICENSE_TYPE=${ENV_LICENSE_TYPE}
${ENV_CONTENT}"
        fi
        ENV_CONTENT="INFLUXDB_EMAIL=${LICENSE_EMAIL}
${ENV_CONTENT}"
    fi
    # The PEM spans many lines; compose reads a double-quoted value as one
    # string. It goes last so single-line readers never meet its lines.
    if [ -n "$ENV_JWT_KEY" ]; then
        ENV_CONTENT="${ENV_CONTENT}
JWT_PRIVATE_KEY=\"${ENV_JWT_KEY}\""
    fi

    # umask protects a new file; chmod covers an existing one
    (
        umask 077
        printf '%s\n' "$ENV_CONTENT" > "$DOCKER_DIR/.env"
    ) && chmod 600 "$DOCKER_DIR/.env"
}

# Utility function to read one single-line value from the Docker .env file
# Parameters:
#   $1 - env file path
#   $2 - key
# Returns: 1 when the file or key is missing
read_env_value() {
    ENV_FILE="$1"
    KEY="$2"

    if [ ! -f "$ENV_FILE" ]; then
        return 1
    fi
    VALUE=$(grep "^${KEY}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2-)
    if [ -z "$VALUE" ]; then
        return 1
    fi
    echo "$VALUE"
    return 0
}

# Utility function to read the multi-line JWT_PRIVATE_KEY from the Docker .env file
# Parameters:
#   $1 - env file path
# Returns: 1 when the file or key is missing
read_env_jwt_private_key() {
    ENV_FILE="$1"

    if [ ! -f "$ENV_FILE" ]; then
        return 1
    fi
    VALUE=$(sed -n '/^JWT_PRIVATE_KEY="/,/"$/p' "$ENV_FILE" 2>/dev/null | sed -e '1s/^JWT_PRIVATE_KEY="//' -e '$s/"$//')
    if [ -z "$VALUE" ]; then
        return 1
    fi
    printf '%s\n' "$VALUE"
    return 0
}

# Function to configure Explorer via file
configure_explorer_via_file() {
    TOKEN="$1"
    INFLUXDB_URL="$2"
    SERVER_NAME="$3"
    DOCKER_DIR="$4"

    printf "├─ Configuring Explorer...\n"

    # Ensure config directory exists with correct permissions
    mkdir -p "$DOCKER_DIR/explorer/config"
    chmod 755 "$DOCKER_DIR/explorer/config"

    # Create the config.json file
    cat > "$DOCKER_DIR/explorer/config/config.json" <<EOF
{
  "DEFAULT_INFLUX_SERVER": "$INFLUXDB_URL",
  "DEFAULT_API_TOKEN": "$TOKEN",
  "DEFAULT_SERVER_NAME": "$SERVER_NAME"
}
EOF

    chmod 640 "$DOCKER_DIR/explorer/config/config.json"

    return 0
}

# Utility function to extract existing token from Explorer config
extract_token_from_explorer_config() {
    DOCKER_DIR="$1"
    CONFIG_FILE="$DOCKER_DIR/explorer/config/config.json"

    if [ -f "$CONFIG_FILE" ]; then
        TOKEN=$(grep '"DEFAULT_API_TOKEN"' "$CONFIG_FILE" | cut -d'"' -f4)
        if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && [ "$TOKEN" != "YOUR_TOKEN_HERE" ]; then
            echo "$TOKEN"
            return 0
        fi
    fi
    echo ""
    return 1
}

# ==============================================================================
# SECTION 6: DOCKER COMPOSE ORCHESTRATION
# ==============================================================================
# High-level Docker Compose setup workflow

# Unified function to setup Docker Compose (both Core and Enterprise)
setup_docker_compose() {
    EDITION_TYPE="$1"  # "core" or "enterprise"
    DOCKER_DIR="${2:-$HOME/.influxdb/docker}"
    LICENSE_EMAIL="$3"
    LICENSE_TYPE="$4"
    LICENSE_PROMPTED=""  # set when the prompt runs

    # Set edition-specific values
    if [ "$EDITION_TYPE" = "enterprise" ]; then
        EDITION_NAME="Enterprise"
        CONTAINER_NAME="influxdb3-enterprise"
        SERVER_NAME="InfluxDB 3 Enterprise"
    else
        EDITION_NAME="Core"
        CONTAINER_NAME="influxdb3-core"
        SERVER_NAME="InfluxDB 3 Core"
    fi

    # Enterprise 3.12.0+ serves the Explorer UI from the server itself with
    # user authentication, so no Explorer container runs and no token is
    # created. Core, and Enterprise below 3.12.0, keep the Explorer container.
    # The image is pinned to INFLUXDB_VERSION, so the check matches the
    # version that runs.
    if has_embedded_ui; then
        USE_EMBEDDED_UI=true
    else
        USE_EMBEDDED_UI=false
    fi

    printf "\n${BOLD}Setting up InfluxDB 3 ${EDITION_NAME}${NC}\n"

    # Verify Docker is running before doing any setup work (silent check)
    if ! check_docker; then
        printf "${RED}Error: Docker is not running${NC}\n\n"
        printf "${BOLD}Docker Connection Failed${NC}\n"
        printf "Docker is not responding. Please ensure Docker Desktop is running.\n\n"
        printf "${BOLD}How to fix:${NC}\n"
        printf "  • Open Docker Desktop and wait for it to start\n"
        printf "  • Check Docker Desktop status in your system tray\n"
        printf "  • Run ${BOLD}docker info${NC} to verify Docker is responding\n"
        printf "  • Restart Docker Desktop if necessary, then run this script again\n\n"
        return 1
    fi

    # Fail fast on a missing image before prompting or touching an existing stack.
    if ! check_docker_image; then
        return 1
    fi

    # Enterprise-specific: Handle license prompting
    if [ "$EDITION_TYPE" = "enterprise" ]; then
        # Check for existing license in shared data directory
        if [ -f "$HOME/.influxdb/data/cluster0/trial_or_home_license" ]; then
            printf "├─${DIM} Found existing license file${NC}\n"
        elif [ -z "$LICENSE_EMAIL" ]; then
            # Prompt for license if not provided
            printf "\n${BOLD}License Setup Required${NC}\n"
            printf "1) ${GREEN}Trial${NC} ${DIM}- Full features for 30 days (up to 256 cores)${NC}\n"
            printf "2) ${GREEN}Home${NC} ${DIM}- Free for non-commercial use (max 2 cores, single node)${NC}\n"
            printf "\nEnter your choice (1-2): "
            read -r LICENSE_CHOICE

            case "${LICENSE_CHOICE:-1}" in
                1) LICENSE_TYPE="trial" ;;
                2) LICENSE_TYPE="home" ;;
                *) LICENSE_TYPE="trial" ;;
            esac
            LICENSE_PROMPTED="$LICENSE_TYPE"

            printf "Enter your email: "
            read -r LICENSE_EMAIL
            while [ -z "$LICENSE_EMAIL" ]; do
                printf "Email is required. Enter your email: "
                read -r LICENSE_EMAIL
            done
        fi
    fi

    printf "├─ Creating directories\n"
    create_docker_directories "$DOCKER_DIR" "$USE_EMBEDDED_UI"

    # Stop any existing containers before reconfiguring; the old file is
    # what removes an older layout's Explorer container
    if [ -f "$DOCKER_DIR/docker-compose.yml" ]; then
        printf "├─ Stopping existing containers\n"
        cd "$DOCKER_DIR"
        if ! DOWN_OUTPUT=$(docker compose down 2>&1); then
            printf "├─${YELLOW} Warning: could not stop the existing containers; they may still be running${NC}\n"
            printf "%s\n" "$DOWN_OUTPUT" | sed 's/^/│  /'
        fi
        cd - > /dev/null
    fi

    # Check for available ports. The embedded UI shares the InfluxDB port.
    INFLUXDB_PORT=$(find_next_available_port "$INFLUXDB_PORT")
    if [ "$USE_EMBEDDED_UI" = false ]; then
        EXPLORER_PORT=$(find_next_available_port "$EXPLORER_PORT")
    fi

    # Reuse the session secret from a previous run unless it is malformed,
    # so Explorer sessions survive a re-run
    SESSION_SECRET=$(read_env_value "$DOCKER_DIR/.env" "SESSION_SECRET") || SESSION_SECRET=""
    if ! is_session_secret "$SESSION_SECRET"; then
        if [ -n "$SESSION_SECRET" ]; then
            printf "├─${YELLOW} Warning: SESSION_SECRET in %s/.env is not a usable session secret; generating a new one${NC}\n" "$DOCKER_DIR"
        fi
        if ! SESSION_SECRET=$(generate_session_secret); then
            printf "└─ ${RED}Error: Could not generate a session secret from /dev/urandom${NC}\n\n"
            return 1
        fi
    fi

    # Keep the stored email and license type when an existing license file skipped the prompt
    if [ "$EDITION_TYPE" = "enterprise" ] && [ -z "$LICENSE_EMAIL" ]; then
        LICENSE_EMAIL=$(read_env_value "$DOCKER_DIR/.env" "INFLUXDB_EMAIL") || LICENSE_EMAIL=""
    fi
    if [ "$EDITION_TYPE" = "enterprise" ] && [ -z "$LICENSE_TYPE" ]; then
        LICENSE_TYPE=$(read_env_value "$DOCKER_DIR/.env" "INFLUXDB_LICENSE_TYPE") || LICENSE_TYPE=""
        case "$LICENSE_TYPE" in
            trial|home|"") ;;
            *)
                printf "├─${YELLOW} Warning: INFLUXDB_LICENSE_TYPE in %s/.env is not trial or home; ignoring it${NC}\n" "$DOCKER_DIR"
                LICENSE_TYPE=""
                ;;
        esac
    fi

    # Reuse the JWT signing key from a previous run unless it is malformed,
    # so user sign-ins survive a re-run. A new key is generated after the
    # image pull, with the openssl inside the image.
    JWT_PRIVATE_KEY=""
    if [ "$USE_EMBEDDED_UI" = true ]; then
        JWT_PRIVATE_KEY=$(read_env_jwt_private_key "$DOCKER_DIR/.env") || JWT_PRIVATE_KEY=""
        if [ -n "$JWT_PRIVATE_KEY" ] && ! is_jwt_private_key "$JWT_PRIVATE_KEY"; then
            printf "├─${YELLOW} Warning: JWT_PRIVATE_KEY in %s/.env is not a PKCS#1 RSA key; generating a new one. Users will need to sign in again.${NC}\n" "$DOCKER_DIR"
            JWT_PRIVATE_KEY=""
        fi
    fi

    printf "├─ Creating docker-compose.yml (%s)\n" "$DOCKER_IMAGE"
    generate_docker_compose_yaml "$EDITION_TYPE" "$DOCKER_DIR" "$LICENSE_TYPE" "$USE_EMBEDDED_UI"
    if ! write_env_file "$EDITION_TYPE" "$SESSION_SECRET" "$LICENSE_EMAIL" "$DOCKER_DIR" "$LICENSE_TYPE" "$JWT_PRIVATE_KEY"; then
        printf "└─ ${RED}Error: Could not write %s${NC}\n\n" "$DOCKER_DIR/.env"
        return 1
    fi

    cd "$DOCKER_DIR"

    # Pull InfluxDB image
    if ! pull_docker_image "$CONTAINER_NAME" "InfluxDB 3 ${EDITION_NAME}" "true"; then
        return 1
    fi

    # First run with the embedded UI: generate the signing key with the
    # pulled image's openssl, then write .env again with the key in it
    if [ "$USE_EMBEDDED_UI" = true ] && [ -z "$JWT_PRIVATE_KEY" ]; then
        printf "├─ Generating the JWT signing key..."
        if ! JWT_PRIVATE_KEY=$(generate_jwt_private_key "$DOCKER_IMAGE"); then
            printf "${RED}FAILED${NC}\n"
            printf "└─ ${RED}Error: Could not generate an RSA key with openssl in %s, openssl, or ssh-keygen${NC}\n\n" "$DOCKER_IMAGE"
            return 1
        fi
        if ! write_env_file "$EDITION_TYPE" "$SESSION_SECRET" "$LICENSE_EMAIL" "$DOCKER_DIR" "$LICENSE_TYPE" "$JWT_PRIVATE_KEY"; then
            printf "${RED}FAILED${NC}\n"
            printf "└─ ${RED}Error: Could not write %s${NC}\n\n" "$DOCKER_DIR/.env"
            return 1
        fi
        printf "SUCCESS\n"
    fi

    docker compose up -d --remove-orphans "$CONTAINER_NAME" 2>&1 | filter_docker_output

    # Wait for InfluxDB to be ready, with the same timeouts as the binary path
    if [ "$EDITION_TYPE" = "enterprise" ]; then
        STARTUP_TIMEOUT="$STARTUP_TIMEOUT_ENTERPRISE"
    else
        STARTUP_TIMEOUT="$STARTUP_TIMEOUT_CORE"
    fi
    if ! wait_for_container_ready "$CONTAINER_NAME" "startup time:" "$STARTUP_TIMEOUT" "$EDITION_TYPE" "$LICENSE_PROMPTED"; then
        return 1
    fi

    if [ "$USE_EMBEDDED_UI" = true ]; then
        # Smoke check. The server loads the UI before its HTTP listener starts
        # and serves / without a token, so the UI answers as soon as the
        # readiness check above does; one request is enough. The result only
        # selects the summary wording and whether the browser opens. It never
        # changes the exit status. The browser's setup page creates the first
        # admin; the script creates no users and no tokens.
        UI_READY=false
        printf "└─ Checking InfluxDB 3 Explorer..."
        if curl -sf --max-time 5 -o /dev/null "http://localhost:${INFLUXDB_PORT}/"; then
            printf "SUCCESS\n"
            UI_READY=true
            open_browser_url "http://localhost:${INFLUXDB_PORT}"
        else
            printf "${YELLOW}no response${NC}\n"
        fi

        if [ "$UI_READY" = true ]; then
            printf "\n${BOLDGREEN}✓ InfluxDB 3 ${EDITION_NAME} with InfluxDB 3 Explorer successfully deployed${NC}\n\n"
        else
            printf "\n${BOLDGREEN}✓ InfluxDB 3 ${EDITION_NAME} successfully deployed${NC}\n\n"
        fi
        printf "${BOLD}Access Points:${NC}\n"
        printf "├─ Explorer UI:  ${BLUE}http://localhost:${INFLUXDB_PORT}${NC}\n"
        printf "└─ InfluxDB API: ${BLUE}http://localhost:${INFLUXDB_PORT}${NC}\n\n"

        printf "${BOLD}Storage Locations:${NC}\n"
        printf "├─ InfluxDB Data:    ${DIM}%s/.influxdb/data${NC}\n" "$HOME"
        printf "└─ InfluxDB Plugins: ${DIM}%s/.influxdb/plugins${NC}\n\n" "$HOME"

        printf "${BOLD}Configuration Files:${NC}\n"
        printf "├─ Docker Compose:   ${DIM}%s/docker-compose.yml${NC}\n" "$DOCKER_DIR"
        printf "└─ Secrets:          ${DIM}%s/.env${NC}\n\n" "$DOCKER_DIR"

        printf "${BOLD}Open Explorer UI:${NC} ${BLUE}http://localhost:${INFLUXDB_PORT}${NC}\n"
        if [ "$UI_READY" = false ]; then
            printf "${DIM}If the page does not load, check: docker logs %s${NC}\n" "$CONTAINER_NAME"
        fi
        printf "\n"

        return 0
    fi

    # Check for existing token in Explorer config, or create new one
    CONFIG_FILE="$DOCKER_DIR/explorer/config/config.json"
    TOKEN_IS_NEW=false
    EXPLORER_DEPLOYED=false

    if [ -f "$CONFIG_FILE" ]; then
        printf "└─ Found existing Explorer config\n\n"
        TOKEN=$(extract_token_from_explorer_config "$DOCKER_DIR")

        if [ -n "$TOKEN" ]; then
            TOKEN_IS_NEW=false
        else
            printf "   ${YELLOW}Config exists but no valid token found${NC}\n"
            printf "   Creating new operator token\n"
            TOKEN=$(create_operator_token "$CONTAINER_NAME")
            TOKEN_IS_NEW=true
            printf "\n"
        fi
    else
        printf "└─ Creating operator token\n"
        TOKEN=$(create_operator_token "$CONTAINER_NAME")
        TOKEN_IS_NEW=true
        printf "\n"
    fi

    # Display token BEFORE launching Explorer (only if newly created)
    if [ "$TOKEN" != "$MANUAL_TOKEN_MSG" ] && [ "$TOKEN" != "TOKEN_ALREADY_EXISTS" ]; then
        if [ "$TOKEN_IS_NEW" = true ]; then
            printf "${BOLD}════════════════════════════════════════════════════════════${NC}\n"
            printf "${BOLD}OPERATOR TOKEN: Save this token. It will not be shown again.${NC}\n"
            printf "%s\n" "$TOKEN"
            printf "${BOLD}════════════════════════════════════════════════════════════${NC}\n\n"
        fi

        # Now launch Explorer after showing the token
        printf "${BOLD}Setting up InfluxDB 3 Explorer...${NC}\n"

        # Pull Explorer image
        pull_docker_image "influxdb3-explorer" "InfluxDB 3 Explorer" "false"

        # Configure Explorer (use port 8181 for container-to-container communication)
        configure_explorer_via_file "$TOKEN" "http://${CONTAINER_NAME}:8181" "$SERVER_NAME" "$DOCKER_DIR"
        docker compose up -d influxdb3-explorer 2>&1 | filter_docker_output

        # Wait for Explorer to be ready
        if wait_for_explorer_ready 60; then
            EXPLORER_DEPLOYED=true
            open_browser_url "http://localhost:${EXPLORER_PORT}/system-overview"
        fi
    else
        # Token creation failed - prepare Explorer but don't start it
        printf "${BOLD}Setting up InfluxDB 3 Explorer...${NC}\n"

        # Pull Explorer image
        pull_docker_image "influxdb3-explorer" "InfluxDB 3 Explorer" "false"

        # Configure Explorer with placeholder token
        configure_explorer_via_file "YOUR_TOKEN_HERE" "http://${CONTAINER_NAME}:8181" "$SERVER_NAME" "$DOCKER_DIR"

        printf "└─ Explorer prepared (manual token configuration required)\n\n"
    fi

    # Display success message and access points AFTER Explorer launch
    if [ "$EXPLORER_DEPLOYED" = true ]; then
        printf "\n${BOLDGREEN}✓ InfluxDB 3 ${EDITION_NAME} with InfluxDB 3 Explorer successfully deployed${NC}\n\n"
    else
        printf "\n${BOLDGREEN}✓ InfluxDB 3 ${EDITION_NAME} successfully deployed${NC}\n\n"
    fi
    printf "${BOLD}Access Points:${NC}\n"
    if [ "$EXPLORER_DEPLOYED" = true ]; then
        printf "├─ Explorer UI:  ${BLUE}http://localhost:${EXPLORER_PORT}${NC}\n"
    fi
    printf "└─ InfluxDB API: ${BLUE}http://localhost:${INFLUXDB_PORT}${NC}\n\n"

    printf "${BOLD}Storage Locations:${NC}\n"
    printf "├─ InfluxDB Data:    ${DIM}%s/.influxdb/data${NC}\n" "$HOME"
    if [ "$EXPLORER_DEPLOYED" = true ]; then
        printf "├─ InfluxDB Plugins: ${DIM}%s/.influxdb/plugins${NC}\n" "$HOME"
        printf "└─ Explorer DB:      ${DIM}%s/explorer/db${NC}\n\n" "$DOCKER_DIR"
    else
        printf "└─ InfluxDB Plugins: ${DIM}%s/.influxdb/plugins${NC}\n\n" "$HOME"
    fi

    printf "${BOLD}Configuration Files:${NC}\n"
    printf "├─ Docker Compose:   ${DIM}%s/docker-compose.yml${NC}\n" "$DOCKER_DIR"
    printf "└─ Explorer Config:  ${DIM}%s/explorer/config/config.json${NC}\n\n" "$DOCKER_DIR"

    # Show manual setup instructions if Explorer was not deployed
    if [ "$EXPLORER_DEPLOYED" = false ]; then
        printf "${BOLD}To Complete InfluxDB 3 Explorer Setup:${NC}\n"
        printf "1. Replace ${DIM}\"YOUR_TOKEN_HERE\"${NC} with your admin token in the Explorer config file:\n"
        printf "   ${DIM}%s/explorer/config/config.json${NC}\n\n" "$DOCKER_DIR"
        printf "2. Start InfluxDB 3 Explorer:\n"
        printf "   ${DIM}cd %s && docker compose up -d influxdb3-explorer${NC}\n\n" "$DOCKER_DIR"
        printf "3. Open your browser to http://localhost:${EXPLORER_PORT}\n\n"
    fi

    return 0
}

# ==============================================================================
# SECTION 7: BINARY INSTALLATION UTILITIES
# ==============================================================================
# Low-level binary installation helpers

# --- Quick Start Configuration ---

# Function to set up Quick Start defaults for both Core and Enterprise
setup_quick_start_defaults() {
    edition="${1:-core}"

    NODE_ID="node0"
    STORAGE_TYPE="File Storage"
    STORAGE_PATH="$HOME/.influxdb/data"
    PLUGIN_PATH="$HOME/.influxdb/plugins"
    STORAGE_FLAGS="--object-store=file --data-dir ${STORAGE_PATH} --plugin-dir ${PLUGIN_PATH}"
    STORAGE_FLAGS_ECHO="--object-store=file --data-dir ${STORAGE_PATH} --plugin-dir ${PLUGIN_PATH}"
    START_SERVICE="y"  # Always set for Quick Start

    # Enterprise-specific settings
    if [ "$edition" = "enterprise" ]; then
        CLUSTER_ID="cluster0"
        LICENSE_FILE_PATH="${STORAGE_PATH}/${CLUSTER_ID}/trial_or_home_license"
    fi

    # Create directories
    mkdir -p "${STORAGE_PATH}"
    mkdir -p "${PLUGIN_PATH}"
}

# --- Cloud Storage Configuration ---

# Function to configure AWS S3 storage
configure_aws_s3_storage() {
    printf "\n"
    printf "${BOLD}AWS S3 Configuration${NC}\n"
    printf "├─ Enter AWS Access Key ID: "
    read -r AWS_KEY

    printf "├─ Enter AWS Secret Access Key: "
    stty -echo
    read -r AWS_SECRET
    stty echo

    printf "\n"
    printf "├─ Enter S3 Bucket: "
    read -r AWS_BUCKET

    printf "└─ Enter AWS Region (default: us-east-1): "
    read -r AWS_REGION
    AWS_REGION=${AWS_REGION:-"us-east-1"}

    STORAGE_FLAGS="--object-store=s3 --bucket=${AWS_BUCKET}"
    if [ -n "$AWS_REGION" ]; then
        STORAGE_FLAGS="$STORAGE_FLAGS --aws-default-region=${AWS_REGION}"
    fi
    STORAGE_FLAGS="$STORAGE_FLAGS --aws-access-key-id=${AWS_KEY}"
    STORAGE_FLAGS_ECHO="$STORAGE_FLAGS --aws-secret-access-key=..."
    STORAGE_FLAGS="$STORAGE_FLAGS --aws-secret-access-key=${AWS_SECRET}"
}

# Function to configure Azure storage
configure_azure_storage() {
    printf "\n"
    printf "${BOLD}Azure Storage Configuration${NC}\n"
    printf "├─ Enter Storage Account Name: "
    read -r AZURE_ACCOUNT

    printf "└─ Enter Storage Access Key: "
    stty -echo
    read -r AZURE_KEY
    stty echo

    printf "\n"
    STORAGE_FLAGS="--object-store=azure --azure-storage-account=${AZURE_ACCOUNT}"
    STORAGE_FLAGS_ECHO="$STORAGE_FLAGS --azure-storage-access-key=..."
    STORAGE_FLAGS="$STORAGE_FLAGS --azure-storage-access-key=${AZURE_KEY}"
}

# Function to configure Google Cloud storage
configure_google_cloud_storage() {
    printf "\n"
    printf "${BOLD}Google Cloud Storage Configuration${NC}\n"
    printf "└─ Enter path to service account JSON file: "
    read -r GOOGLE_SA
    STORAGE_FLAGS="--object-store=google --google-service-account=${GOOGLE_SA}"
    STORAGE_FLAGS_ECHO="$STORAGE_FLAGS"
}

# --- Enterprise License ---

# Function to set up license for Enterprise Quick Start
setup_license_for_quick_start() {
    # Check if license file exists
    if [ -f "$LICENSE_FILE_PATH" ]; then
        printf "${DIM}Found existing license file, using it for quick start.${NC}\n"
        LICENSE_TYPE=""
        LICENSE_EMAIL=""
        LICENSE_DESC="Existing"
    else
        # Prompt for license type and email only
        printf "\n"
        printf "${BOLD}License Setup Required${NC}\n"
        printf "1) ${GREEN}Trial${NC} ${DIM}- Full features for 30 days (up to 256 cores)${NC}\n"
        printf "2) ${GREEN}Home${NC} ${DIM}- Free for non-commercial use (max 2 cores, single node)${NC}\n"
        printf "\n"
        printf "Enter your choice (1-2): "
        read -r LICENSE_CHOICE

        case "${LICENSE_CHOICE:-1}" in
            1)
                LICENSE_TYPE="trial"
                LICENSE_DESC="Trial"
                ;;
            2)
                LICENSE_TYPE="home"
                LICENSE_DESC="Home"
                ;;
            *)
                LICENSE_TYPE="trial"
                LICENSE_DESC="Trial"
                ;;
        esac

        printf "Enter your email: "
        read -r LICENSE_EMAIL
        while [ -z "$LICENSE_EMAIL" ]; do
            printf "Email is required. Enter your email: "
            read -r LICENSE_EMAIL
        done
    fi
}

# --- Storage Configuration Prompts ---

# Function to prompt for storage configuration
prompt_storage_configuration() {
    # Prompt for storage solution
    printf "\n"
    printf "${BOLD}Select Your Storage Solution${NC}\n"
    printf "├─ 1) File storage (Persistent)\n"
    printf "├─ 2) Object storage (Persistent)\n"
    printf "├─ 3) In-memory storage (Non-persistent)\n"
    printf "└─ Enter your choice (1-3): "
    read -r STORAGE_CHOICE

    case "$STORAGE_CHOICE" in
        1)
            STORAGE_TYPE="File Storage"
            printf "\n"
            printf "Enter storage path (default: %s/data): " "${INSTALL_LOC}"
            read -r STORAGE_PATH
            STORAGE_PATH=${STORAGE_PATH:-"$INSTALL_LOC/data"}
            STORAGE_FLAGS="--object-store=file --data-dir ${STORAGE_PATH}"
            STORAGE_FLAGS_ECHO="$STORAGE_FLAGS"
            ;;
        2)
            STORAGE_TYPE="Object Storage"
            printf "\n"
            printf "${BOLD}Select Cloud Provider${NC}\n"
            printf "├─ 1) Amazon S3\n"
            printf "├─ 2) Azure Storage\n"
            printf "├─ 3) Google Cloud Storage\n"
            printf "└─ Enter your choice (1-3): "
            read -r CLOUD_CHOICE

            case $CLOUD_CHOICE in
                1)  # AWS S3
                    configure_aws_s3_storage
                    ;;

                2)  # Azure Storage
                    configure_azure_storage
                    ;;

                3)  # Google Cloud Storage
                    configure_google_cloud_storage
                    ;;

                *)
                    printf "Invalid cloud provider choice. Defaulting to file storage.\n"
                    STORAGE_TYPE="File Storage"
                    STORAGE_FLAGS="--object-store=file --data-dir $INSTALL_LOC/data"
                    STORAGE_FLAGS_ECHO="$STORAGE_FLAGS"
                    ;;
            esac
            ;;
        3)
            STORAGE_TYPE="memory"
            STORAGE_FLAGS="--object-store=memory"
            STORAGE_FLAGS_ECHO="$STORAGE_FLAGS"
            ;;

        *)
            printf "Invalid choice. Defaulting to file storage.\n"
            STORAGE_TYPE="File Storage"
            STORAGE_FLAGS="--object-store=file --data-dir $INSTALL_LOC/data"
            STORAGE_FLAGS_ECHO="$STORAGE_FLAGS"
            ;;
    esac
}

# --- Server Management ---

# Function to perform health check on server
perform_server_health_check() {
    timeout_seconds="${1:-$STARTUP_TIMEOUT_CORE}"
    is_enterprise="${2:-false}"

    SUCCESS=0
    EMAIL_MESSAGE_SHOWN=false

    for i in $(seq 1 "$timeout_seconds"); do
        # on systems without a usable lsof, sleep a second to see if the pid is
        # still there to give influxdb a chance to error out in case an already
        # running influxdb is running on this port
        if [ -z "$lsof_exec" ]; then
            sleep 1
        fi

        if ! kill -0 "$PID" 2>/dev/null ; then
            if [ "$is_enterprise" = "true" ]; then
                printf "└─${DIM} Server process stopped unexpectedly${NC}\n"
            fi
            break
        fi

        if curl --max-time 1 -s "http://localhost:$PORT/health" >/dev/null 2>&1; then
            printf "\n${BOLDGREEN}✓ InfluxDB 3 ${EDITION} is now installed and running on port %s. Nice!${NC}\n" "$PORT"
            SUCCESS=1
            break
        fi

        # Show email verification message after 10 seconds for a new license
        if [ "$is_enterprise" = "true" ] && [ -n "${LICENSE_TYPE:-}" ] && [ "$i" -eq 10 ] && [ "$EMAIL_MESSAGE_SHOWN" = "false" ]; then
            print_license_verification_notice
            EMAIL_MESSAGE_SHOWN=true
        fi

        # Show progress updates every 15 seconds after initial grace period
        if [ "$is_enterprise" = "true" ] && [ -n "${LICENSE_TYPE:-}" ] && [ "$i" -gt 5 ] && [ $((i % 15)) -eq 0 ]; then
            print_license_verification_progress "$i" "$timeout_seconds"
        fi

        sleep 1
    done

    if [ $SUCCESS -eq 0 ]; then
        print_startup_timeout_error "$timeout_seconds" "$is_enterprise" "${LICENSE_TYPE:-}" "$PORT" "$LOG_FILE"
        if [ "$is_enterprise" = "true" ]; then
            # Kill the background process if it's still running
            if kill -0 "$PID" 2>/dev/null; then
                printf "   Stopping background server process...\n"
                kill "$PID" 2>/dev/null
            fi
        else
            exit 1
        fi
    fi
}

# Function to display Enterprise server command
display_enterprise_server_command() {
    is_quick_start="${1:-false}"

    if [ "$is_quick_start" = "true" ]; then
        # Quick Start format
        printf "└─${DIM} Command: ${NC}\n"
        if [ "$USE_EMBEDDED_UI" = true ]; then
            printf "${DIM}   INFLUXDB3_WEBUI_SESSION_SECRET=\"\$(cat '%s')\" \\\\${NC}\n" "$WEBUI_SECRET_FILE"
            printf "${DIM}   INFLUXDB3_JWT_PRIVATE_KEY=\"\$(cat '%s')\" \\\\${NC}\n" "$JWT_KEY_FILE"
        fi
        printf "${DIM}   influxdb3 serve \\\\${NC}\n"
        printf "${DIM}   --cluster-id=%s \\\\${NC}\n" "$CLUSTER_ID"
        printf "${DIM}   --node-id=%s \\\\${NC}\n" "$NODE_ID"
        if [ -n "$LICENSE_TYPE" ] && [ -n "$LICENSE_EMAIL" ]; then
            printf "${DIM}   --license-type=%s \\\\${NC}\n" "$LICENSE_TYPE"
            printf "${DIM}   --license-email=%s \\\\${NC}\n" "$LICENSE_EMAIL"
        fi
        if [ "$USE_EMBEDDED_UI" = true ]; then
            printf "${DIM}   --mode=all,webui --user-auth-type=basic --jwt-key-id=install-script \\\\${NC}\n"
        fi
        printf "${DIM}   --http-bind=0.0.0.0:%s \\\\${NC}\n" "$PORT"
        printf "${DIM}   %s${NC}\n" "$STORAGE_FLAGS_ECHO"
        printf "\n"
    else
        # Custom configuration format
        printf "│\n"
        printf "├─ Running serve command:\n"
        if [ "$USE_EMBEDDED_UI" = true ]; then
            printf "├─${DIM} INFLUXDB3_WEBUI_SESSION_SECRET=\"\$(cat '%s')\" \\\\${NC}\n" "$WEBUI_SECRET_FILE"
            printf "├─${DIM} INFLUXDB3_JWT_PRIVATE_KEY=\"\$(cat '%s')\" \\\\${NC}\n" "$JWT_KEY_FILE"
        fi
        printf "├─${DIM} influxdb3 serve \\\\${NC}\n"
        printf "├─${DIM} --cluster-id='%s' \\\\${NC}\n" "$CLUSTER_ID"
        printf "├─${DIM} --node-id='%s' \\\\${NC}\n" "$NODE_ID"
        printf "├─${DIM} --license-type='%s' \\\\${NC}\n" "$LICENSE_TYPE"
        printf "├─${DIM} --license-email='%s' \\\\${NC}\n" "$LICENSE_EMAIL"
        if [ "$USE_EMBEDDED_UI" = true ]; then
            printf "├─${DIM} --mode='all,webui' --user-auth-type='basic' --jwt-key-id='install-script' \\\\${NC}\n"
        fi
        printf "├─${DIM} --http-bind='0.0.0.0:%s' \\\\${NC}\n" "$PORT"
        printf "├─${DIM} %s${NC}\n" "$STORAGE_FLAGS_ECHO"
        printf "│\n"
    fi
}

# Function to display the Enterprise serve command for a manual start, with
# defaults for anything the user has not chosen yet (troubleshooting after a
# failed startup, and Skip startup)
display_enterprise_manual_command() {
    if [ "$USE_EMBEDDED_UI" = true ]; then
        printf "     INFLUXDB3_WEBUI_SESSION_SECRET=\"\$(cat '%s')\" \\\\\n" "$WEBUI_SECRET_FILE"
        printf "     INFLUXDB3_JWT_PRIVATE_KEY=\"\$(cat '%s')\" \\\\\n" "$JWT_KEY_FILE"
    fi
    printf "     influxdb3 serve \\\\\n"
    printf "     --cluster-id=%s \\\\\n" "${CLUSTER_ID:-cluster0}"
    printf "     --node-id=%s \\\\\n" "${NODE_ID:-node0}"
    printf "     --license-type=%s \\\\\n" "${LICENSE_TYPE:-trial}"
    printf "     --license-email=%s \\\\\n" "${LICENSE_EMAIL:-your@email.com}"
    if [ "$USE_EMBEDDED_UI" = true ]; then
        printf "     --mode=all,webui --user-auth-type=basic --jwt-key-id=install-script \\\\\n"
    fi
    printf "     --http-bind=0.0.0.0:%s \\\\\n" "$PORT"
    printf "     %s\n" "${STORAGE_FLAGS_ECHO:-"--object-store=file --data-dir $INSTALL_LOC/data --plugin-dir $INSTALL_LOC/plugins"}"
}

# --- Embedded Explorer UI with user auth (Enterprise 3.12.0+) ---

# Write $2 to $1 as a file readable only by its owner
# Returns: 1 when the file cannot be written
write_private_file() {
    # umask protects a new file; chmod covers an existing one
    (
        umask 077
        printf '%s\n' "$2" > "$1"
    ) && chmod 600 "$1"
}

# Load the embedded UI session secret from the script-owned file, creating
# the file when it is missing, and export the secret for the server launch.
# The server requires a secret whenever webui is on. It is passed through the
# environment, not a flag, so it does not appear in the process list, and it
# is reused on every run so that a re-run does not sign browsers out.
# Exits: 1 when the secret cannot be generated or the file cannot be written
load_webui_session_secret() {
    WEBUI_SESSION_SECRET=""
    if [ -f "$WEBUI_SECRET_FILE" ]; then
        WEBUI_SESSION_SECRET=$(cat "$WEBUI_SECRET_FILE" 2>/dev/null) || WEBUI_SESSION_SECRET=""
    fi
    # A malformed file (failed write, hand edit) is replaced
    if ! is_session_secret "$WEBUI_SESSION_SECRET"; then
        if [ -n "$WEBUI_SESSION_SECRET" ]; then
            printf "\n${YELLOW}Warning: '%s' does not hold a usable session secret; generating a new one. Browsers signed in to Explorer will need to sign in again.${NC}\n" "$WEBUI_SECRET_FILE" >&2
        fi
        if ! WEBUI_SESSION_SECRET=$(generate_session_secret); then
            printf "\n${RED}Error:${NC} Could not generate the Explorer session secret from /dev/urandom.\n" >&2
            exit 1
        fi
        if ! write_private_file "$WEBUI_SECRET_FILE" "$WEBUI_SESSION_SECRET"; then
            printf "\n${RED}Error:${NC} Could not write the Explorer session secret to '%s'.\n" "$WEBUI_SECRET_FILE" >&2
            exit 1
        fi
    fi
    export INFLUXDB3_WEBUI_SESSION_SECRET="$WEBUI_SESSION_SECRET"
}

# Load the JWT signing key from the script-owned file, creating the file when
# it is missing, and export the key for the server launch. The server signs
# user sign-in tokens with it and accepts only a PKCS#1 RSA key; a bad key
# does not stop the server, it only disables sign-in. The key is passed
# through the environment, not a flag, and reused on every run so that a
# re-run does not sign users out.
# Exits: 1 when no key can be generated or the file cannot be written
load_jwt_private_key() {
    JWT_PRIVATE_KEY=""
    if [ -f "$JWT_KEY_FILE" ]; then
        JWT_PRIVATE_KEY=$(cat "$JWT_KEY_FILE" 2>/dev/null) || JWT_PRIVATE_KEY=""
    fi
    # A malformed file (PKCS#8, truncated, hand edit) is replaced
    if ! is_jwt_private_key "$JWT_PRIVATE_KEY"; then
        if [ -n "$JWT_PRIVATE_KEY" ]; then
            printf "\n${YELLOW}Warning: '%s' is not a PKCS#1 RSA private key; generating a new one. Users will need to sign in again.${NC}\n" "$JWT_KEY_FILE" >&2
        fi
        if ! JWT_PRIVATE_KEY=$(generate_jwt_private_key ""); then
            printf "\n${RED}Error:${NC} Could not generate the JWT signing key. Install openssl or ssh-keygen and run this script again.\n" >&2
            exit 1
        fi
        if ! write_private_file "$JWT_KEY_FILE" "$JWT_PRIVATE_KEY"; then
            printf "\n${RED}Error:${NC} Could not write the JWT signing key to '%s'.\n" "$JWT_KEY_FILE" >&2
            exit 1
        fi
    fi
    export INFLUXDB3_JWT_PRIVATE_KEY="$JWT_PRIVATE_KEY"
}

# Smoke check for the embedded UI. The server loads the UI before its HTTP
# listener starts and serves / without a token, so the UI answers as soon as
# /health does; one request is enough. The result only selects the summary
# wording and whether the browser opens. It never changes the exit status.
# Sets: UI_READY
check_embedded_ui() {
    UI_READY=false
    printf "\n${BOLD}Checking InfluxDB 3 Explorer${NC}\n"
    if curl -sf --max-time 5 -o /dev/null "http://localhost:${PORT}/"; then
        printf "└─ Explorer is served by InfluxDB on port %s\n" "$PORT"
        UI_READY=true
        open_browser_url "http://localhost:${PORT}"
    else
        printf "└─ ${YELLOW}Explorer did not respond at http://localhost:%s/${NC}\n" "$PORT"
    fi
}

# ==============================================================================
# SECTION 8: MAIN INSTALLATION FLOW
# ==============================================================================

# --- Phase 1: Welcome and Pre-Checks ---

# Attempt to clear screen and show welcome message
clear 2>/dev/null || true  # clear isn't available everywhere
printf "┌───────────────────────────────────────────────────┐\n"
printf "│ ${BOLD}Welcome to InfluxDB!${NC} We'll make this quick.       │\n"
printf "└───────────────────────────────────────────────────┘\n"

# Check for edition mismatch
CURRENT_EDITION=""
if [ -f "$HOME/.influxdb/docker/docker-compose.yml" ]; then
    if grep -q "influxdb3-enterprise:" "$HOME/.influxdb/docker/docker-compose.yml" 2>/dev/null; then
        CURRENT_EDITION="Enterprise"
    elif grep -q "influxdb3-core:" "$HOME/.influxdb/docker/docker-compose.yml" 2>/dev/null; then
        CURRENT_EDITION="Core"
    fi
elif [ -f "$HOME/.influxdb/influxdb3" ]; then
    # Binary exists - try to detect edition from binary if possible
    # For now, we'll need the user to have run it at least once
    if [ -d "$HOME/.influxdb/data" ]; then
        # Check for Enterprise-specific license file
        if find "$HOME/.influxdb/data" -name "trial_or_home_license" 2>/dev/null | grep -q .; then
            CURRENT_EDITION="Enterprise"
        else
            CURRENT_EDITION="Core"
        fi
    fi
fi

# Display notice if trying to install different edition
if [ -n "$CURRENT_EDITION" ] && [ "$CURRENT_EDITION" != "$EDITION" ]; then
    printf "\n${YELLOW}Notice:${NC} You have InfluxDB 3 ${BOLD}%s${NC} currently installed, but are installing InfluxDB 3 ${BOLD}%s${NC}.\n" "$CURRENT_EDITION" "$EDITION"
    if [ "$EDITION" = "Enterprise" ]; then
        printf "To install %s, remove 'enterprise' as an argument to your script execution command.\n" "$CURRENT_EDITION"
    else
        printf "To install %s, add 'enterprise' as an argument to your script execution command.\n" "$CURRENT_EDITION"
    fi
fi

# --- Phase 2: Installation Type Selection ---

printf "\n"
printf "${BOLD}Select Installation Type${NC}\n"
printf "\n"
printf "1) ${GREEN}Docker Compose${NC}  ${DIM}(Installs InfluxDB 3 %s + Explorer UI)${NC}\n" "$EDITION"
printf "2) ${GREEN}Simple Download${NC} ${DIM}(Binary installation, no dependencies)${NC}\n"
printf "\n"
printf "Enter your choice (1-2): "
read -r INSTALL_TYPE

case "$INSTALL_TYPE" in
    1)
        # Docker Compose installation
        if ! check_docker; then
            printf "\n${RED}Error:${NC} Docker is not installed or not running, or you are not in the Docker user group.\n"
            printf "Please install Docker Desktop or Docker Engine with the compose plugin and try again.\n"
            printf "Visit: ${BLUE}https://www.docker.com/${NC}\n\n"
            exit 1
        fi

        # Set default installation directory
        DOCKER_DIR="$HOME/.influxdb/docker"

        # Run appropriate setup based on edition. The call is unguarded so -e
        # still applies inside the function; exit $? propagates a nonzero
        # return when the script runs without -e.
        if [ "$EDITION" = "Enterprise" ]; then
            setup_docker_compose "enterprise" "$DOCKER_DIR"
        else
            setup_docker_compose "core" "$DOCKER_DIR"
        fi

        exit $?
        ;;
    2)
        # Binary installation selected - proceed directly with download
        printf "\n\n"
        ;;
    *)
        printf "Invalid choice. Defaulting to binary installation.\n\n"
        ;;
esac

# attempt to find the user's shell config
shellrc=
if [ -n "$SHELL" ]; then
    tmp=~/.$(basename "$SHELL")rc
    if [ -e "$tmp" ]; then
        shellrc="$tmp"
    fi
fi

check_release_url "${URL}"

printf "\n"
printf "${BOLD}Downloading InfluxDB 3 %s to %s${NC}\n" "$EDITION" "$INSTALL_LOC"
printf "├─${DIM} mkdir -p '%s'${NC}\n" "$INSTALL_LOC"
mkdir -p "$INSTALL_LOC"
download_file "${URL}" "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz"

printf "\n"
printf "${BOLD}Verifying '%s/influxdb3-${EDITION_TAG}.tar.gz'${NC}\n" "$INSTALL_LOC"
download_file "${URL}.sha256" "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz.sha256"
dl_sha=$(cut -d ' ' -f 1 "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz.sha256" | grep -E '^[0-9a-f]{64}$')
if [ -z "$dl_sha" ]; then
    printf "Could not find properly formatted SHA256 in '%s/influxdb3-${EDITION_TAG}.tar.gz.sha256'. Aborting.\n" "$INSTALL_LOC"
    exit 1
fi

ch_sha=
if [ "${OS}" = "Darwin" ]; then
    printf "└─${DIM} shasum -a 256 '%s/influxdb3-${EDITION_TAG}.tar.gz'" "$INSTALL_LOC"
    ch_sha=$(shasum -a 256 "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz" | cut -d ' ' -f 1)
else
    printf "└─${DIM} sha256sum '%s/influxdb3-${EDITION_TAG}.tar.gz'" "$INSTALL_LOC"
    ch_sha=$(sha256sum "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz" | cut -d ' ' -f 1)
fi
if [ "$ch_sha" = "$dl_sha" ]; then
    printf " (OK: %s = %s)${NC}\n" "$ch_sha" "$dl_sha"
else
    printf " (Error: %s != %s). Aborting.${NC}\n" "$ch_sha" "$dl_sha"
    exit 1
fi
printf "└─${DIM} rm '%s/influxdb3-${EDITION_TAG}.tar.gz.sha256'${NC}\n" "$INSTALL_LOC"
rm "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz.sha256"

printf "\n"
printf "${BOLD}Extracting and Processing${NC}\n"

# some tarballs have a leading component, check for that
TAR_LEVEL=0
if tar -tf "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz" | grep -q '[a-zA-Z0-9]/influxdb3$' ; then
    TAR_LEVEL=1
fi
printf "├─${DIM} tar -xf '%s/influxdb3-${EDITION_TAG}.tar.gz' --strip-components=${TAR_LEVEL} -C '%s'${NC}\n" "$INSTALL_LOC" "$INSTALL_LOC"
tar -xf "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz" --strip-components="${TAR_LEVEL}" -C "$INSTALL_LOC"

printf "└─${DIM} rm '%s/influxdb3-${EDITION_TAG}.tar.gz'${NC}\n" "$INSTALL_LOC"
rm "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz"

if [ -n "$shellrc" ] && ! grep -q "export PATH=.*$INSTALL_LOC" "$shellrc"; then
    printf "\n"
    printf "${BOLD}Adding InfluxDB to '%s'${NC}\n" "$shellrc"
    printf "└─${DIM} export PATH=\"\$PATH:%s/\" >> '%s'${NC}\n" "$INSTALL_LOC" "$shellrc"
    echo "export PATH=\"\$PATH:$INSTALL_LOC/\"" >> "$shellrc"
fi

export INFLUXDB3_SERVE_INVOCATION_METHOD="install-script"

# Enterprise 3.12.0+ serves the Explorer UI from the server with user
# authentication. Every startup choice, including Skip, loads or creates the
# session secret and the JWT signing key so that the displayed serve command
# is real. The browser's setup page creates the first admin; the script
# creates no users and no tokens. Core and older Enterprise are unchanged.
USE_EMBEDDED_UI=false
UI_FLAGS=""
UI_READY=false
if has_embedded_ui; then
    USE_EMBEDDED_UI=true
    UI_FLAGS="--mode=all,webui --user-auth-type=basic --jwt-key-id=install-script"
    load_webui_session_secret
    load_jwt_private_key
fi

if [ "${EDITION}" = "Core" ]; then
    # Prompt user for startup options
    printf "\n"
    printf "${BOLD}What would you like to do next?${NC}\n"
    printf "1) ${GREEN}Quick Start${NC} ${DIM}(recommended; data stored at %s/data)${NC}\n" "${INSTALL_LOC}"
    printf "2) ${GREEN}Custom Configuration${NC} ${DIM}(configure all options manually)${NC}\n"
    printf "3) ${GREEN}Skip startup${NC} ${DIM}(install only)${NC}\n"
    printf "\n"
    printf "Enter your choice (1-3): "
    read -r STARTUP_CHOICE
    STARTUP_CHOICE=${STARTUP_CHOICE:-1}

    case "$STARTUP_CHOICE" in
        1)
            # Quick Start - use defaults
            setup_quick_start_defaults core
            ;;
        2)
            # Custom Configuration - existing detailed flow
            START_SERVICE="y"
            ;;
        3)
            # Skip startup
            START_SERVICE="n"
            ;;
        *)
            printf "Invalid choice. Using Quick Start (option 1).\n"
            setup_quick_start_defaults core
            ;;
    esac

    if [ "$START_SERVICE" = "y" ] && [ "$STARTUP_CHOICE" = "2" ]; then
        # Prompt for Node ID
        printf "\n"
        printf "${BOLD}Enter Your Node ID${NC}\n"
        printf "├─ A Node ID is a unique, uneditable identifier for a service.\n"
        printf "└─ Enter a Node ID (default: node0): "
        read -r NODE_ID
        NODE_ID=${NODE_ID:-node0}

        # Prompt for storage solution
        prompt_storage_configuration

        # Ensure port is available; if not, find a new one.
        PORT=$(find_next_available_port "$PORT")

        # Start and give up to 30 seconds to respond
        printf "\n"

        # Create logs directory and generate timestamped log filename
        mkdir -p "$INSTALL_LOC/logs"
        LOG_FILE="$INSTALL_LOC/logs/$(date +%Y%m%d_%H%M%S).log"

        printf "${BOLD}Starting InfluxDB${NC}\n"
        printf "├─${DIM} Node ID: %s${NC}\n" "$NODE_ID"
        printf "├─${DIM} Storage: %s${NC}\n" "$STORAGE_TYPE"
        printf "├─${DIM} Logs: %s${NC}\n" "$LOG_FILE"
        printf "├─${DIM} influxdb3 serve \\\\${NC}\n"
        printf "├─${DIM}   --node-id='%s' \\\\${NC}\n" "$NODE_ID"
        printf "├─${DIM}   --http-bind='0.0.0.0:%s' \\\\${NC}\n" "$PORT"
        printf "└─${DIM}   %s${NC}\n" "$STORAGE_FLAGS_ECHO"

        "$INSTALL_LOC/$BINARY_NAME" serve --node-id="$NODE_ID" --http-bind="0.0.0.0:$PORT" $STORAGE_FLAGS >> "$LOG_FILE" 2>&1 &
        PID="$!"

        perform_server_health_check "$STARTUP_TIMEOUT_CORE"

    elif [ "$START_SERVICE" = "y" ] && [ "$STARTUP_CHOICE" = "1" ]; then
        # Quick Start flow - minimal output, just start the server
        printf "\n"
        printf "${BOLD}Starting InfluxDB (Quick Start)${NC}\n"
        printf "├─${DIM} Node ID: %s${NC}\n" "$NODE_ID"
        printf "├─${DIM} Storage: %s/data${NC}\n" "${INSTALL_LOC}"
        printf "├─${DIM} Plugins: %s/plugins${NC}\n" "${INSTALL_LOC}"
        printf "├─${DIM} Logs: %s/logs/$(date +%Y%m%d_%H%M%S).log${NC}\n" "${INSTALL_LOC}"

        # Ensure port is available; if not, find a new one.
        ORIGINAL_PORT="$PORT"
        PORT=$(find_next_available_port "$PORT")

        # Show port result
        if [ "$PORT" != "$ORIGINAL_PORT" ]; then
            printf "├─${DIM} Found available port: %s (%s-%s in use)${NC}\n" "$PORT" "$ORIGINAL_PORT" "$((PORT - 1))"
        fi

        # Show the command being executed
        printf "└─${DIM} Command:${NC}\n"
        printf "${DIM}    influxdb3 serve \\\\${NC}\n"
        printf "${DIM}     --node-id=%s \\\\${NC}\n" "$NODE_ID"
        printf "${DIM}     --http-bind=0.0.0.0:%s \\\\${NC}\n" "$PORT"
        printf "${DIM}     %s${NC}\n\n" "$STORAGE_FLAGS_ECHO"

        # Create logs directory and generate timestamped log filename
        mkdir -p "$INSTALL_LOC/logs"
        LOG_FILE="$INSTALL_LOC/logs/$(date +%Y%m%d_%H%M%S).log"

        # Start server in background
        "$INSTALL_LOC/$BINARY_NAME" serve --node-id="$NODE_ID" --http-bind="0.0.0.0:$PORT" $STORAGE_FLAGS >> "$LOG_FILE" 2>&1 &
        PID="$!"

        perform_server_health_check "$STARTUP_TIMEOUT_CORE"

    else
        printf "\n"
        printf "${BOLDGREEN}✓ InfluxDB 3 ${EDITION} is now installed. Nice!${NC}\n"
    fi
else
    # Enterprise startup options
    printf "\n"
    printf "${BOLD}What would you like to do next?${NC}\n"
    printf "1) ${GREEN}Quick Start${NC} ${DIM}(recommended; data stored at %s/data)${NC}\n" "${INSTALL_LOC}"
    printf "2) ${GREEN}Custom Configuration${NC} ${DIM}(configure all options manually)${NC}\n"
    printf "3) ${GREEN}Skip startup${NC} ${DIM}(install only)${NC}\n"
    printf "\n"
    printf "Enter your choice (1-3): "
    read -r STARTUP_CHOICE
    STARTUP_CHOICE=${STARTUP_CHOICE:-1}

    case "$STARTUP_CHOICE" in
        3)
            # Skip startup
            START_SERVICE="n"
            ;;
        2)
            # Custom Configuration - existing detailed flow
            START_SERVICE="y"
            ;;
        1|*)
            # Quick Start - use defaults and check for existing license
            if [ "$STARTUP_CHOICE" != "1" ]; then
                printf "Invalid choice. Using Quick Start (option 1).\n"
            fi
            setup_quick_start_defaults enterprise
            setup_license_for_quick_start
            START_SERVICE="y"
            ;;
    esac

    if [ "$START_SERVICE" = "y" ] && [ "$STARTUP_CHOICE" = "1" ]; then
        # Enterprise Quick Start flow
        printf "\n"
        printf "${BOLD}Starting InfluxDB Enterprise (Quick Start)${NC}\n"
        printf "├─${DIM} Cluster ID: %s${NC}\n" "$CLUSTER_ID"
        printf "├─${DIM} Node ID: %s${NC}\n" "$NODE_ID"
        if [ -n "$LICENSE_TYPE" ]; then
            printf "├─${DIM} License Type: %s${NC}\n" "$LICENSE_DESC"
        fi
        if [ -n "$LICENSE_EMAIL" ]; then
            printf "├─${DIM} Email: %s${NC}\n" "$LICENSE_EMAIL"
        fi
        printf "├─${DIM} Storage: %s/data${NC}\n" "${INSTALL_LOC}"
        printf "├─${DIM} Plugins: %s/plugins${NC}\n" "${INSTALL_LOC}"
        if [ "$USE_EMBEDDED_UI" = true ]; then
            printf "├─${DIM} Explorer UI: embedded, user auth (secrets in %s and %s)${NC}\n" "$WEBUI_SECRET_FILE" "$JWT_KEY_FILE"
        fi

        # Create logs directory and generate timestamped log filename
        mkdir -p "$INSTALL_LOC/logs"
        LOG_FILE="$INSTALL_LOC/logs/$(date +%Y%m%d_%H%M%S).log"
        printf "├─${DIM} Logs: %s${NC}\n" "$LOG_FILE"

        # Ensure port is available; if not, find a new one.
        ORIGINAL_PORT="$PORT"
        PORT=$(find_next_available_port "$PORT")

        # Show port result
        if [ "$PORT" != "$ORIGINAL_PORT" ]; then
            printf "├─${DIM} Found available port: %s (%s-%s in use)${NC}\n" "$PORT" "$ORIGINAL_PORT" "$((PORT - 1))"
        fi

        # Show the command being executed
        display_enterprise_server_command true

        # Start server in background with or without license flags. The
        # session secret and signing key, when the UI is on, are already
        # exported.
        if [ -n "$LICENSE_TYPE" ] && [ -n "$LICENSE_EMAIL" ]; then
            # New license needed
            "$INSTALL_LOC/$BINARY_NAME" serve --cluster-id="$CLUSTER_ID" --node-id="$NODE_ID" --license-type="$LICENSE_TYPE" --license-email="$LICENSE_EMAIL" $UI_FLAGS --http-bind="0.0.0.0:$PORT" $STORAGE_FLAGS >> "$LOG_FILE" 2>&1 &
        else
            # Existing license file
            "$INSTALL_LOC/$BINARY_NAME" serve --cluster-id="$CLUSTER_ID" --node-id="$NODE_ID" $UI_FLAGS --http-bind="0.0.0.0:$PORT" $STORAGE_FLAGS >> "$LOG_FILE" 2>&1 &
        fi
        PID="$!"

        printf "├─${DIM} Server started in background (PID: %s)${NC}\n" "$PID"

        perform_server_health_check "$STARTUP_TIMEOUT_ENTERPRISE" true

    elif [ "$START_SERVICE" = "y" ] && [ "$STARTUP_CHOICE" = "2" ]; then
        # Enterprise Custom Start flow
        printf "\n"
        # Prompt for Cluster ID
        printf "${BOLD}Enter Your Cluster ID${NC}\n"
        printf "├─ A Cluster ID determines part of the storage path hierarchy.\n"
        printf "├─ All nodes within the same cluster share this identifier.\n"
        printf "└─ Enter a Cluster ID (default: cluster0): "
        read -r CLUSTER_ID
        CLUSTER_ID=${CLUSTER_ID:-cluster0}

        # Prompt for Node ID
        printf "\n"
        printf "${BOLD}Enter Your Node ID${NC}\n"
        printf "├─ A Node ID distinguishes individual server instances within the cluster.\n"
        printf "└─ Enter a Node ID (default: node0): "
        read -r NODE_ID
        NODE_ID=${NODE_ID:-node0}

        # Prompt for license type
        printf "\n"
        printf "${BOLD}Select Your License Type${NC}\n"
        printf "├─ 1) Trial - Full features for 30 days (up to 256 cores)\n"
        printf "├─ 2) Home - Free for non-commercial use (max 2 cores, single node)\n"
        printf "└─ Enter your choice (1-2): "
        read -r LICENSE_CHOICE

        case "$LICENSE_CHOICE" in
            1)
                LICENSE_TYPE="trial"
                LICENSE_DESC="Trial"
                ;;
            2)
                LICENSE_TYPE="home"
                LICENSE_DESC="Home"
                ;;
            *)
                printf "Invalid choice. Defaulting to trial.\n"
                LICENSE_TYPE="trial"
                LICENSE_DESC="Trial"
                ;;
        esac

        # Prompt for email
        printf "\n"
        printf "${BOLD}Enter Your Email Address${NC}\n"
        printf "├─ Required for license verification and activation\n"
        printf "├─${YELLOW} IMPORTANT: You MUST verify your email to activate the license${NC}\n"
        printf "├─${BOLD} → Check your inbox after entering your email${NC}\n"
        printf "└─ Email: "
        read -r LICENSE_EMAIL

        while [ -z "$LICENSE_EMAIL" ]; do
            printf "├─ Email address is required. Please enter your email: "
            read -r LICENSE_EMAIL
        done

        # Prompt for storage solution
        prompt_storage_configuration

        # Ensure port is available; if not, find a new one.
        PORT=$(find_next_available_port "$PORT")

        # Start Enterprise in background with licensing and give up to 90 seconds to respond (licensing takes longer)
        printf "\n"
        printf "${BOLD}Starting InfluxDB Enterprise${NC}\n"
        printf "├─${DIM} Cluster ID: %s${NC}\n" "$CLUSTER_ID"
        printf "├─${DIM} Node ID: %s${NC}\n" "$NODE_ID"
        printf "├─${DIM} License Type: %s${NC}\n" "$LICENSE_DESC"
        printf "├─${DIM} Email: %s${NC}\n" "$LICENSE_EMAIL"
        printf "├─${DIM} Storage: %s${NC}\n" "$STORAGE_TYPE"
        if [ "$USE_EMBEDDED_UI" = true ]; then
            printf "├─${DIM} Explorer UI: embedded, user auth (secrets in %s and %s)${NC}\n" "$WEBUI_SECRET_FILE" "$JWT_KEY_FILE"
        fi

        # Create logs directory and generate timestamped log filename
        mkdir -p "$INSTALL_LOC/logs"
        LOG_FILE="$INSTALL_LOC/logs/$(date +%Y%m%d_%H%M%S).log"
        printf "├─${DIM} Logs: %s${NC}\n" "$LOG_FILE"

        display_enterprise_server_command false

        # Start server in background; the session secret and signing key,
        # when the UI is on, are already exported
        "$INSTALL_LOC/$BINARY_NAME" serve --cluster-id="$CLUSTER_ID" --node-id="$NODE_ID" --license-type="$LICENSE_TYPE" --license-email="$LICENSE_EMAIL" $UI_FLAGS --http-bind="0.0.0.0:$PORT" $STORAGE_FLAGS >> "$LOG_FILE" 2>&1 &
        PID="$!"

        printf "├─${DIM} Server started in background (PID: %s)${NC}\n" "$PID"

        perform_server_health_check "$STARTUP_TIMEOUT_ENTERPRISE" true

    else
        printf "\n"
        printf "${BOLDGREEN}✓ InfluxDB 3 ${EDITION} is now installed. Nice!${NC}\n"
    fi

    # With the UI on and the server up, check the UI and open the browser.
    # Nothing runs after a failed startup or a skipped one.
    if [ "$USE_EMBEDDED_UI" = true ] && [ "${SUCCESS:-0}" -eq 1 ]; then
        check_embedded_ui
    fi
fi

### SUCCESS INFORMATION ###
printf "\n"
if [ "${EDITION}" = "Enterprise" ] && [ "$SUCCESS" -eq 0 ] 2>/dev/null; then
    printf "${BOLD}Server startup failed${NC} - troubleshooting options:\n"
    printf "├─ ${BOLD}${YELLOW}Check email verification:${NC} ${BOLD}Look for verification email and click the link${NC}\n"
    printf "├─ ${BOLD}   → This is the most common issue for Enterprise activation${NC}\n"
    printf "├─ ${BOLD}Manual startup:${NC} Try running the server manually to see detailed logs:\n"
    display_enterprise_manual_command
    if [ "$USE_EMBEDDED_UI" = true ]; then
        printf "├─ ${BOLD}Open Explorer UI:${NC} ${BLUE}http://localhost:%s${NC} once the server is running\n" "$PORT"
    fi
    printf "└─ ${BOLD}Common issues:${NC} Network connectivity, invalid email format, port conflicts\n"
else
    printf "${BOLD}Next Steps${NC}\n"
    if [ -n "$shellrc" ]; then
        printf "├─ Run ${BOLD}source '%s'${NC}, then access InfluxDB with ${BOLD}influxdb3${NC} command.\n" "$shellrc"
    else
        printf "├─ Access InfluxDB with the ${BOLD}influxdb3${NC} command.\n"
    fi
    if [ "$USE_EMBEDDED_UI" = true ] && [ "${SUCCESS:-0}" -eq 1 ]; then
        printf "├─ ${BOLD}Open Explorer UI:${NC} ${BLUE}http://localhost:%s${NC}\n" "$PORT"
        if [ "$UI_READY" = false ]; then
            printf "│  ${DIM}If the page does not load, check the log: %s${NC}\n" "$LOG_FILE"
        fi
    elif [ "$USE_EMBEDDED_UI" = true ]; then
        # Installed without starting: show the command that enables the UI
        printf "├─ Start InfluxDB with the embedded Explorer UI:\n"
        display_enterprise_manual_command
        printf "├─ ${BOLD}Open Explorer UI:${NC} ${BLUE}http://localhost:%s${NC} once the server is running\n" "$PORT"
    else
        printf "├─ Create admin token: ${BOLD}influxdb3 create token --admin${NC}\n"
    fi
    printf "└─ Begin writing data! Learn more at https://docs.influxdata.com/influxdb3/${EDITION_TAG}/get-started/write/\n\n"
fi

# Explorer is a separate install only where the server does not embed it
if [ "$USE_EMBEDDED_UI" = false ]; then
    printf "┌────────────────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│ Looking to use a UI for querying, plugins, management, and more?                       │\n"
    printf "│ Get InfluxDB 3 Explorer at ${BLUE}https://docs.influxdata.com/influxdb3/explorer/#quick-start${NC} │\n"
    printf "└────────────────────────────────────────────────────────────────────────────────────────┘\n\n"
fi
