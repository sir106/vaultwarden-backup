#!/bin/bash

# Test dashboard functionality
cd "$(dirname "$0")" || exit 1

DOCKER_IMAGE="ttionya/vaultwarden-backup:test"
DATA_DIR="$(pwd)/tests/fixtures/source/bitwarden/data"
OUTPUT_DIR="output"
REMOTE_DIR="/${OUTPUT_DIR}"

echo "======================================"
echo "Testing Dashboard Functionality"
echo "======================================"

# Test 1: dashboard-admin-token
echo ""
echo "Test 1: Dashboard Admin Token"
echo "======================================"
TEST_NAME="dashboard-admin-token"
TEST_OUTPUT_DIR="$(pwd)/${OUTPUT_DIR}/${TEST_NAME}"
TEST_CONTAINER_NAME="vaultwarden_backup_${TEST_NAME//-/_}"
TEST_TOKEN="dashboard-test-token"

mkdir -p "${TEST_OUTPUT_DIR}"

# Create initial backup
docker run --rm \
    --mount "type=bind,source=${TEST_OUTPUT_DIR},target=${REMOTE_DIR}" \
    --mount "type=bind,source=${DATA_DIR},target=/bitwarden/data/" \
    -e "RCLONE_REMOTE_DIR=${REMOTE_DIR}" \
    -e "BACKUP_FILE_SUFFIX=test" \
    "${DOCKER_IMAGE}" \
    backup

# Start dashboard container
docker run -d \
    --name "${TEST_CONTAINER_NAME}" \
    --mount "type=bind,source=${TEST_OUTPUT_DIR},target=${REMOTE_DIR}" \
    --mount "type=bind,source=${DATA_DIR},target=/bitwarden/data/" \
    -e "RCLONE_REMOTE_DIR=${REMOTE_DIR}" \
    -e "DASHBOARD_ENABLE=TRUE" \
    -e "ADMIN_TOKEN=${TEST_TOKEN}" \
    -e "CRON=0 0 31 2 *" \
    "${DOCKER_IMAGE}"

# Wait for container to start
sleep 5

# Test unauthorized access
STATUS_UNAUTHORIZED=$(docker exec "${TEST_CONTAINER_NAME}" curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/cgi-bin/api/backups/recent" 2>/dev/null)
echo "Unauthorized status: ${STATUS_UNAUTHORIZED} (expected 401)"

# Test authorized access
STATUS_AUTHORIZED=$(docker exec "${TEST_CONTAINER_NAME}" curl -s -o /dev/null -w "%{http_code}" -H "X-Admin-Token: ${TEST_TOKEN}" "http://127.0.0.1:8080/cgi-bin/api/backups/recent" 2>/dev/null)
echo "Authorized status: ${STATUS_AUTHORIZED} (expected 200)"

# Cleanup
docker stop "${TEST_CONTAINER_NAME}" >/dev/null 2>&1
docker rm "${TEST_CONTAINER_NAME}" >/dev/null 2>&1

if [[ "${STATUS_UNAUTHORIZED}" == "401" ]] && [[ "${STATUS_AUTHORIZED}" == "200" ]]; then
    echo "✓ Test 1 PASSED"
    TEST1_PASS=true
else
    echo "✗ Test 1 FAILED"
    TEST1_PASS=false
fi

# Test 2: dashboard-recent-backups
echo ""
echo "Test 2: Dashboard Recent Backups"
echo "======================================"
TEST_NAME="dashboard-recent-backups"
TEST_OUTPUT_DIR="$(pwd)/${OUTPUT_DIR}/${TEST_NAME}"
TEST_CONTAINER_NAME="vaultwarden_backup_${TEST_NAME//-/_}"
TEST_TOKEN="dashboard-test-token"

mkdir -p "${TEST_OUTPUT_DIR}"

# Create initial backup
docker run --rm \
    --mount "type=bind,source=${TEST_OUTPUT_DIR},target=${REMOTE_DIR}" \
    --mount "type=bind,source=${DATA_DIR},target=/bitwarden/data/" \
    -e "RCLONE_REMOTE_DIR=${REMOTE_DIR}" \
    -e "BACKUP_FILE_SUFFIX=test" \
    "${DOCKER_IMAGE}" \
    backup

# Start dashboard container
docker run -d \
    --name "${TEST_CONTAINER_NAME}" \
    --mount "type=bind,source=${TEST_OUTPUT_DIR},target=${REMOTE_DIR}" \
    --mount "type=bind,source=${DATA_DIR},target=/bitwarden/data/" \
    -e "RCLONE_REMOTE_DIR=${REMOTE_DIR}" \
    -e "DASHBOARD_ENABLE=TRUE" \
    -e "ADMIN_TOKEN=${TEST_TOKEN}" \
    -e "CRON=0 0 31 2 *" \
    "${DOCKER_IMAGE}"

# Wait for container to start
sleep 5

# Get recent backups
RECENT_JSON=$(docker exec "${TEST_CONTAINER_NAME}" curl -s -H "X-Admin-Token: ${TEST_TOKEN}" "http://127.0.0.1:8080/cgi-bin/api/backups/recent?limit=5" 2>/dev/null)

echo "Response: ${RECENT_JSON}"

# Check response format
if echo "${RECENT_JSON}" | grep -F '"ok":true' > /dev/null 2>&1; then
    echo "✓ Response format is valid"
    RESPONSE_VALID=true
else
    echo "✗ Response format is invalid"
    RESPONSE_VALID=false
fi

# Check if backup file is in response
if echo "${RECENT_JSON}" | grep -F 'backup.test' > /dev/null 2>&1; then
    echo "✓ Backup file found in response"
    BACKUP_FOUND=true
else
    echo "✗ Backup file not found in response"
    BACKUP_FOUND=false
fi

# Cleanup
docker stop "${TEST_CONTAINER_NAME}" >/dev/null 2>&1
docker rm "${TEST_CONTAINER_NAME}" >/dev/null 2>&1

if [[ "${RESPONSE_VALID}" == "true" ]] && [[ "${BACKUP_FOUND}" == "true" ]]; then
    echo "✓ Test 2 PASSED"
    TEST2_PASS=true
else
    echo "✗ Test 2 FAILED"
    TEST2_PASS=false
fi

# Summary
echo ""
echo "======================================"
echo "Test Summary"
echo "======================================"
if [[ "${TEST1_PASS}" == "true" ]] && [[ "${TEST2_PASS}" == "true" ]]; then
    echo "✓ All dashboard tests PASSED"
    exit 0
else
    echo "✗ Some dashboard tests FAILED"
    exit 1
fi
