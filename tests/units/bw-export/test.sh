#!/bin/bash

TEST_NAME="bw-export"
TEST_OUTPUT_DIR="$(pwd)/${OUTPUT_DIR}/${TEST_NAME}"
TEST_TEMP_DIR="$(pwd)/${TEMP_DIR}/${TEST_NAME}"

PASSWORD="0ddd9b27-ca9b-4912-b6fb-76569ec5cac1"
FAILED_NUM=0

color yellow "Starting test case \"${TEST_NAME}\""

function prepare() {
    mkdir -p "${TEST_OUTPUT_DIR}" "${TEST_TEMP_DIR}"
}

function test() {
    color blue "Testing bw CLI availability in docker image..."

    BW_VERSION=$(docker run --rm "${DOCKER_IMAGE}" bw --version 2>&1)
    if [[ $? != 0 || -z "${BW_VERSION}" ]]; then
        color red "bw CLI is not available in docker image"
        ((FAILED_NUM++))
    else
        color green "bw CLI version: ${BW_VERSION}"
    fi

    color blue "Testing missing BW_SERVER_URL validation..."
    FOUND_MESSAGE_COUNT=$(docker run --rm \
        --mount "type=bind,source=${DATA_DIR},target=/bitwarden/data" \
        --mount "type=bind,source=${TEST_OUTPUT_DIR},target=${REMOTE_DIR}" \
        -e "RCLONE_REMOTE_DIR=${REMOTE_DIR}" \
        -e "ZIP_PASSWORD=${PASSWORD}" \
        -e "BW_EXPORT_ENABLE=TRUE" \
        "${DOCKER_IMAGE}" \
        backup | grep -c "BW_SERVER_URL is required when BW_EXPORT_ENABLE is TRUE")

    if [[ "${FOUND_MESSAGE_COUNT}" -ne 1 ]]; then
        color red "Missing BW_SERVER_URL validation failed"
        ((FAILED_NUM++))
    fi

    color blue "Testing missing BW_CLIENTID/SECRET validation..."
    FOUND_MESSAGE_COUNT=$(docker run --rm \
        --mount "type=bind,source=${DATA_DIR},target=/bitwarden/data" \
        --mount "type=bind,source=${TEST_OUTPUT_DIR},target=${REMOTE_DIR}" \
        -e "RCLONE_REMOTE_DIR=${REMOTE_DIR}" \
        -e "ZIP_PASSWORD=${PASSWORD}" \
        -e "BW_EXPORT_ENABLE=TRUE" \
        -e "BW_SERVER_URL=https://vaultwarden.example.com" \
        "${DOCKER_IMAGE}" \
        backup | grep -c "BW_CLIENTID and BW_CLIENTSECRET are required when BW_EXPORT_ENABLE is TRUE")

    if [[ "${FOUND_MESSAGE_COUNT}" -ne 1 ]]; then
        color red "Missing BW_CLIENTID validation failed"
        ((FAILED_NUM++))
    fi

    color blue "Testing missing BW_PASSWORD validation..."
    FOUND_MESSAGE_COUNT=$(docker run --rm \
        --mount "type=bind,source=${DATA_DIR},target=/bitwarden/data" \
        --mount "type=bind,source=${TEST_OUTPUT_DIR},target=${REMOTE_DIR}" \
        -e "RCLONE_REMOTE_DIR=${REMOTE_DIR}" \
        -e "ZIP_PASSWORD=${PASSWORD}" \
        -e "BW_EXPORT_ENABLE=TRUE" \
        -e "BW_SERVER_URL=https://vaultwarden.example.com" \
        -e "BW_CLIENTID=user.test" \
        -e "BW_CLIENTSECRET=testsecret" \
        "${DOCKER_IMAGE}" \
        backup | grep -c "BW_PASSWORD is required when BW_EXPORT_ENABLE is TRUE")

    if [[ "${FOUND_MESSAGE_COUNT}" -ne 1 ]]; then
        color red "Missing BW_PASSWORD validation failed"
        ((FAILED_NUM++))
    fi
}

function cleanup() {
    sudo rm -rf "${TEST_OUTPUT_DIR}" "${TEST_TEMP_DIR}"

    unset TEST_OUTPUT_DIR
    unset TEST_TEMP_DIR
    unset PASSWORD
    unset FAILED_NUM
    unset FOUND_MESSAGE_COUNT
    unset BW_VERSION
}

prepare
test
cleanup

test_result "${TEST_NAME}" "${FAILED_NUM}"
