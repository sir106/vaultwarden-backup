#!/bin/bash

TEST_NAME="dashboard-recent-backups"
TEST_CONTAINER_NAME="vaultwarden_backup_${TEST_NAME//-/_}"
TEST_OUTPUT_DIR="$(pwd)/${OUTPUT_DIR}/${TEST_NAME}"
TEST_RESTORE_DIR="$(pwd)/${EXTRACT_DIR}/${TEST_NAME}"
TEST_CONFIG_DIR="$(pwd)/${CONFIG_DIR}/${TEST_NAME}"
TEST_TOKEN="test-backup-token-67890"

FAILED_NUM=0

color yellow "Starting test case \"${TEST_NAME}\""

function prepare() {
    docker rm -f "${TEST_CONTAINER_NAME}" > /dev/null 2>&1 || true
    mkdir -p "${TEST_OUTPUT_DIR}" "${TEST_RESTORE_DIR}" "${TEST_CONFIG_DIR}"

    cat > "${TEST_CONFIG_DIR}/rclone.conf" << 'EOF'
[BitwardenBackup]
type = local
EOF
}

function start() {
    # 1. Create an initial backup file
    docker run --rm \
        --mount "type=bind,source=${TEST_OUTPUT_DIR},target=${REMOTE_DIR}" \
        --mount "type=bind,source=${DATA_DIR},target=/bitwarden/data/" \
        --mount "type=bind,source=${TEST_CONFIG_DIR},target=/root/.config/rclone/" \
        -e "RCLONE_REMOTE_DIR=${REMOTE_DIR}" \
        -e "BACKUP_FILE_SUFFIX=test" \
        "${DOCKER_IMAGE}" \
        backup > /dev/null 2>&1

    # 2. Start dashboard container
    docker run -d \
        --name "${TEST_CONTAINER_NAME}" \
        --mount "type=bind,source=${TEST_OUTPUT_DIR},target=${REMOTE_DIR}" \
        --mount "type=bind,source=${TEST_RESTORE_DIR},target=/bitwarden/data/" \
        --mount "type=bind,source=${TEST_CONFIG_DIR},target=/root/.config/rclone/" \
        -e "RCLONE_REMOTE_DIR=${REMOTE_DIR}" \
        -e "BACKUP_DASHBOARD_ENABLE=TRUE" \
        -e "BACKUP_DASHBOARD_ADMIN_TOKEN=${TEST_TOKEN}" \
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

    # 1. Check recent backups endpoint
    local RECENT_JSON
    RECENT_JSON="$(docker exec "${TEST_CONTAINER_NAME}" curl -s -H "X-Admin-Token: ${TEST_TOKEN}" "http://127.0.0.1:8080/cgi-bin/api/backups/recent?limit=10")"
    if ! echo "${RECENT_JSON}" | grep -F '"ok":true' > /dev/null 2>&1 || ! echo "${RECENT_JSON}" | grep -F 'backup.test.zip' > /dev/null 2>&1; then
        color red "Recent backups list test failed. Response: ${RECENT_JSON}"
        ((FAILED_NUM++))
        return
    fi

    # 2. Execute dry-run
    local DRY_RUN_JSON
    DRY_RUN_JSON="$(docker exec "${TEST_CONTAINER_NAME}" curl -s -X POST -H "X-Admin-Token: ${TEST_TOKEN}" -d "remote=BitwardenBackup:${REMOTE_DIR}&file=backup.test.zip" "http://127.0.0.1:8080/cgi-bin/api/restore/dry-run")"
    if ! echo "${DRY_RUN_JSON}" | grep -F '"ok":true' > /dev/null 2>&1; then
        color red "Dry-run validation failed. Response: ${DRY_RUN_JSON}"
        ((FAILED_NUM++))
        return
    fi

    local DRY_RUN_ID
    DRY_RUN_ID="$(echo "${DRY_RUN_JSON}" | grep -o '"dry_run_id":"[^"]*' | cut -d'"' -f4)"
    if [[ -z "${DRY_RUN_ID}" ]]; then
        color red "Failed to extract dry_run_id from ${DRY_RUN_JSON}"
        ((FAILED_NUM++))
        return
    fi

    # 3. Execute restore
    local EXEC_JSON
    EXEC_JSON="$(docker exec "${TEST_CONTAINER_NAME}" curl -s -X POST -H "X-Admin-Token: ${TEST_TOKEN}" -d "dry_run_id=${DRY_RUN_ID}&force=true" "http://127.0.0.1:8080/cgi-bin/api/restore/execute")"
    if ! echo "${EXEC_JSON}" | grep -F '"ok":true' > /dev/null 2>&1; then
        color red "Restore execution failed. Response: ${EXEC_JSON}"
        ((FAILED_NUM++))
        return
    fi

    local RESTORE_ID
    RESTORE_ID="$(echo "${EXEC_JSON}" | grep -o '"restore_id":"[^"]*' | cut -d'"' -f4)"
    if [[ -z "${RESTORE_ID}" ]]; then
        color red "Failed to extract restore_id from ${EXEC_JSON}"
        ((FAILED_NUM++))
        return
    fi

    # 4. Poll restore status until completion
    local POLL_COUNT=0
    local RESTORE_SUCCESS=FALSE
    while [[ ${POLL_COUNT} -lt 30 ]]; do
        local STATUS_JSON
        STATUS_JSON="$(docker exec "${TEST_CONTAINER_NAME}" curl -s -H "X-Admin-Token: ${TEST_TOKEN}" "http://127.0.0.1:8080/cgi-bin/api/restore/status?id=${RESTORE_ID}")"

        if echo "${STATUS_JSON}" | grep -F '"status":"success"' > /dev/null 2>&1; then
            RESTORE_SUCCESS=TRUE
            break
        elif echo "${STATUS_JSON}" | grep -F '"status":"failed"' > /dev/null 2>&1; then
            color red "Restore job failed according to status: ${STATUS_JSON}"
            break
        fi

        sleep 1
        ((POLL_COUNT++))
    done

    if [[ "${RESTORE_SUCCESS}" != "TRUE" ]]; then
        color red "Restore job did not reach success status within timeout"
        ((FAILED_NUM++))
        return
    fi

    # 5. Check restored files
    check_files_same_in_folders "${DATA_DIR}" "${TEST_RESTORE_DIR}"
    if [[ $? != 0 ]]; then
        color red "Restored data differs from source data"
        ((FAILED_NUM++))
    fi
}

function cleanup() {
    docker stop "${TEST_CONTAINER_NAME}" > /dev/null 2>&1
    docker rm "${TEST_CONTAINER_NAME}" > /dev/null 2>&1

    sudo rm -rf "${TEST_OUTPUT_DIR}" "${TEST_RESTORE_DIR}" "${TEST_CONFIG_DIR}"

    unset TEST_NAME
    unset TEST_CONTAINER_NAME
    unset TEST_OUTPUT_DIR
    unset TEST_RESTORE_DIR
    unset TEST_CONFIG_DIR
    unset TEST_TOKEN
}

prepare
start
test
cleanup

test_result "dashboard-recent-backups" "${FAILED_NUM}"
