#!/bin/sh
# Invoked by test_embedded_ui.py and test_binary_ui.py; all paths refer to
# their temporary directory.
# shellcheck disable=SC2034
set -eu
SCRIPT="$TEST_REPO/install_influxdb.sh"
# shellcheck source=tests/load_install_function.sh
. "$TEST_REPO/tests/load_install_function.sh"

BOLD=""; DIM=""; BLUE=""; NC=""; YELLOW=""; BOLDGREEN=""; RED=""
OS=$(uname -s)
MANUAL_TOKEN_MSG=MANUAL_TOKEN_CREATION_REQUIRED
FIRST_EXPLORER_USER="admin"
EDITION_TYPE=enterprise
EDITION_NAME=Enterprise
EDITION=Enterprise
INFLUXDB_VERSION="$TEST_VERSION"

case "$1" in
    configure|bootstrap)
        # The Docker path: the loaders read and write .env
        for helper in is_session_secret generate_session_secret is_jwt_private_key \
            openssl_pkcs1_key generate_jwt_private_key generate_docker_compose_yaml \
            write_env_file read_env_value read_env_jwt_private_key load_session_secret \
            load_jwt_private_key create_operator_token extract_token_from_explorer_config \
            print_operator_token_box setup_first_explorer_user display_first_user_steps \
            finish_embedded_ui_setup; do
            load_function "$helper"
        done
        DOCKER_IMAGE="influxdb:$TEST_VERSION-enterprise"
        INFLUXDB_PORT="${TEST_PORT:-8181}"
        EXPLORER_PORT=8888
        LICENSE_EMAIL=""
        LICENSE_TYPE=""
        DOCKER_DIR="$TEST_DIR"
        load_session_secret "$TEST_DIR/.env"
        load_jwt_private_key "$TEST_DIR/.env" true
        EXPLORER_USER=$(read_env_value "$TEST_DIR/.env" EXPLORER_USER) || EXPLORER_USER=""
        ;;
esac

case "$1" in
    configure)
        if [ -z "$JWT_PRIVATE_KEY" ]; then
            JWT_PRIVATE_KEY=$(generate_jwt_private_key "$DOCKER_IMAGE")
        fi
        generate_docker_compose_yaml enterprise "$TEST_DIR" "" true
        write_env_file enterprise "$SESSION_SECRET" "" "$TEST_DIR" "" "$JWT_PRIVATE_KEY" "$EXPLORER_USER"
        ;;
    bootstrap)
        # Suppress the desktop side effect; Docker, HTTP and auth remain real.
        open_browser_url() { :; }
        finish_embedded_ui_setup "$TEST_CONTAINER" "$TEST_DIR" > "$TEST_DIR/bootstrap.log"
        printf '%s\n' "$FIRST_USER_STATE" > "$TEST_DIR/user-state"
        printf '%s\n' "$FIRST_USER_OUTPUT" > "$TEST_DIR/user-output"
        ;;
    binary-serve)
        # The binary path: the installer's gate creates or reuses the secret
        # files under $TEST_DIR with the host generators, exports them, and
        # this process becomes the server, started as the installer starts it
        for helper in version_at_least has_embedded_ui is_session_secret \
            generate_session_secret is_jwt_private_key openssl_pkcs1_key \
            generate_jwt_private_key restrict_private_file write_private_file \
            load_webui_session_secret load_webui_jwt_private_key setup_embedded_ui; do
            load_function "$helper"
        done
        INSTALL_LOC="$TEST_DIR"
        WEBUI_SECRET_FILE="$INSTALL_LOC/webui-session-secret"
        JWT_KEY_FILE="$INSTALL_LOC/jwt-private-key.pem"
        setup_embedded_ui
        printf '%s\n' "$UI_FLAGS" > "$TEST_DIR/ui-flags"
        mkdir -p "$TEST_DIR/data" "$TEST_DIR/plugins"
        # shellcheck disable=SC2086  # UI_FLAGS is a list of flags
        exec "$TEST_BINARY" serve --cluster-id=cluster0 --node-id=node0 $UI_FLAGS \
            --http-bind="127.0.0.1:$TEST_PORT" \
            --object-store=file --data-dir "$TEST_DIR/data" --plugin-dir "$TEST_DIR/plugins" \
            --license-file "$TEST_DIR/license.jwt"
        ;;
    *) exit 2 ;;
esac
