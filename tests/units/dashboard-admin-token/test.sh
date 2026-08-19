#!/bin/bash

TEST_NAME="dashboard-admin-token"
TEST_CONTAINER_NAME="vaultwarden_backup_${TEST_NAME//-/_}"
TEST_OUTPUT_DIR="$(pwd)/${OUTPUT_DIR}/${TEST_NAME}"
TEST_CONFIG_DIR="$(pwd)/${CONFIG_DIR}/${TEST_NAME}"
TEST_TOKEN="test-admin-token-12345"

FAILED_NUM=0

color yellow "Starting test case \"${TEST_NAME}\""

function prepare() {
    docker rm -f "${TEST_CONTAINER_NAME}" > /dev/null 2>&1 || true
    mkdir -p "${TEST_OUTPUT_DIR}" "${TEST_CONFIG_DIR}"

    cat > "${TEST_CONFIG_DIR}/rclone.conf" << 'EOF'
[BitwardenBackup]
type = local
EOF
}

function start() {
    docker run -d \
        --name "${TEST_CONTAINER_NAME}" \
        --mount "type=bind,source=${TEST_OUTPUT_DIR},target=${REMOTE_DIR}" \
        --mount "type=bind,source=${DATA_DIR},target=/bitwarden/data/" \
        --mount "type=bind,source=${TEST_CONFIG_DIR},target=/root/.config/rclone/" \
        -e "RCLONE_REMOTE_DIR=${REMOTE_DIR}" \
        -e "DASHBOARD_ENABLE=TRUE" \
        -e "ADMIN_TOKEN=${TEST_TOKEN}" \
        -e "CRON=0 0 31 2 *" \
        "${DOCKER_IMAGE}"
}

function test() {
    color blue "Testing..."

    # Wait for dashboard server to start
    local RETRY=0
    while [[ ${RETRY} -lt 15 ]]; do
        if docker exec "${TEST_CONTAINER_NAME}" curl -s "http://127.0.0.1:8080/cgi-bin/ui" > /dev/null 2>&1; then
            break
        fi
        sleep 1
        ((RETRY++))
    done

    # 1. UI accessibility test
    local UI_CODE
    UI_CODE="$(docker exec "${TEST_CONTAINER_NAME}" curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/cgi-bin/ui")"
    if [[ "${UI_CODE}" != "200" ]]; then
        color red "UI accessibility failed (expected 200, got ${UI_CODE})"
        ((FAILED_NUM++))
    fi

    # 2. Root redirect test
    local ROOT_CODE
    ROOT_CODE="$(docker exec "${TEST_CONTAINER_NAME}" curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/")"
    if [[ "${ROOT_CODE}" != "302" ]]; then
        color red "Root redirection failed (expected 302, got ${ROOT_CODE})"
        ((FAILED_NUM++))
    fi

    # 3. Unauthenticated API request test
    local UNAUTH_CODE
    UNAUTH_CODE="$(docker exec "${TEST_CONTAINER_NAME}" curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/cgi-bin/api/backups/recent")"
    if [[ "${UNAUTH_CODE}" != "401" ]]; then
        color red "Unauthenticated request failed (expected 401, got ${UNAUTH_CODE})"
        ((FAILED_NUM++))
    fi

    # 4. Invalid token API request test
    local INVALID_CODE
    INVALID_CODE="$(docker exec "${TEST_CONTAINER_NAME}" curl -s -o /dev/null -w "%{http_code}" -H "X-Admin-Token: wrong-token" "http://127.0.0.1:8080/cgi-bin/api/backups/recent")"
    if [[ "${INVALID_CODE}" != "401" ]]; then
        color red "Invalid token request failed (expected 401, got ${INVALID_CODE})"
        ((FAILED_NUM++))
    fi

    # 5. Valid X-Admin-Token header request test
    local AUTH_CODE
    AUTH_CODE="$(docker exec "${TEST_CONTAINER_NAME}" curl -s -o /dev/null -w "%{http_code}" -H "X-Admin-Token: ${TEST_TOKEN}" "http://127.0.0.1:8080/cgi-bin/api/backups/recent")"
    if [[ "${AUTH_CODE}" != "200" ]]; then
        color red "Authorized X-Admin-Token request failed (expected 200, got ${AUTH_CODE})"
        ((FAILED_NUM++))
    fi

    # 6. Valid Bearer Authorization header request test
    local BEARER_CODE
    BEARER_CODE="$(docker exec "${TEST_CONTAINER_NAME}" curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TEST_TOKEN}" "http://127.0.0.1:8080/cgi-bin/api/backups/recent")"
    if [[ "${BEARER_CODE}" != "200" ]]; then
        color red "Authorized Bearer request failed (expected 200, got ${BEARER_CODE})"
        ((FAILED_NUM++))
    fi
}

function cleanup() {
    docker stop "${TEST_CONTAINER_NAME}" > /dev/null 2>&1
    docker rm "${TEST_CONTAINER_NAME}" > /dev/null 2>&1

    sudo rm -rf "${TEST_OUTPUT_DIR}" "${TEST_CONFIG_DIR}"

    unset TEST_NAME
    unset TEST_CONTAINER_NAME
    unset TEST_OUTPUT_DIR
    unset TEST_CONFIG_DIR
    unset TEST_TOKEN
}

prepare
start
test
cleanup

test_result "dashboard-admin-token" "${FAILED_NUM}"
