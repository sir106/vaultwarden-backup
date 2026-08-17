#!/bin/bash

. /app/includes.sh

function clear_dir() {
    rm -rf "${BACKUP_DIR}"
}

function backup_init() {
    NOW="$(date +"${BACKUP_FILE_DATE_FORMAT}")"
    # backup vaultwarden database file (sqlite)
    BACKUP_FILE_DB_SQLITE="${BACKUP_DIR}/db.${NOW}.sqlite3"
    # backup vaultwarden database file (postgresql)
    BACKUP_FILE_DB_POSTGRESQL="${BACKUP_DIR}/db.${NOW}.dump"
    # backup vaultwarden database file (mysql)
    BACKUP_FILE_DB_MYSQL="${BACKUP_DIR}/db.${NOW}.sql"
    # backup vaultwarden config file
    BACKUP_FILE_CONFIG="${BACKUP_DIR}/config.${NOW}.json"
    # backup vaultwarden rsakey files
    BACKUP_FILE_RSAKEY="${BACKUP_DIR}/rsakey.${NOW}.tar"
    # backup vaultwarden attachments directory
    BACKUP_FILE_ATTACHMENTS="${BACKUP_DIR}/attachments.${NOW}.tar"
    # backup vaultwarden sends directory
    BACKUP_FILE_SENDS="${BACKUP_DIR}/sends.${NOW}.tar"
    # backup vaultwarden export file
    local BW_EXPORT_EXT="json"
    if [[ "${BW_EXPORT_FORMAT}" == "csv" ]]; then
        BW_EXPORT_EXT="csv"
    fi
    BACKUP_FILE_JSON_EXPORT="${BACKUP_DIR}/export.${NOW}.${BW_EXPORT_EXT}"
    # backup zip file
    BACKUP_FILE_ZIP="${BACKUP_DIR}/backup.${NOW}.${ZIP_TYPE}"
}

function backup_db_sqlite() {
    color blue "backup vaultwarden sqlite database"

    check_file_exist "${DATA_DB}"

    sqlite3 "${DATA_DB}" ".backup '${BACKUP_FILE_DB_SQLITE}'"
    if [[ $? != 0 ]]; then
        color red "backup vaultwarden sqlite database failed"

        send_notification "failure" "Backup failed at $(date +"%Y-%m-%d %H:%M:%S %Z"). Reason: Backup sqlite database failed."

        exit 1
    fi
}

function backup_db_postgresql() {
    color blue "backup vaultwarden postgresql database"

    pg_dump -Fc -h "${PG_HOST}" -p "${PG_PORT}" -d "${PG_DBNAME}" -U "${PG_USERNAME}" -f "${BACKUP_FILE_DB_POSTGRESQL}"
    if [[ $? != 0 ]]; then
        color red "backup vaultwarden postgresql database failed"

        send_notification "failure" "Backup failed at $(date +"%Y-%m-%d %H:%M:%S %Z"). Reason: Backup postgresql database failed."

        exit 1
    fi
}

function backup_db_mysql() {
    color blue "backup vaultwarden mysql database"

    local EXTRA_OPTIONS=()
    if [[ -n "${MYSQL_SSL}" ]]; then
        EXTRA_OPTIONS+=("--ssl=\"${MYSQL_SSL}\"")
    fi
    if [[ -n "${MYSQL_SSL_VERIFY_SERVER_CERT}" ]]; then
        EXTRA_OPTIONS+=("--ssl-verify-server-cert=\"${MYSQL_SSL_VERIFY_SERVER_CERT}\"")
    fi
    if [[ -n "${MYSQL_SSL_CA}" ]]; then
        EXTRA_OPTIONS+=("--ssl-ca=\"${MYSQL_SSL_CA}\"")
    fi
    if [[ -n "${MYSQL_SSL_CERT}" ]]; then
        EXTRA_OPTIONS+=("--ssl-cert=\"${MYSQL_SSL_CERT}\"")
    fi
    if [[ -n "${MYSQL_SSL_KEY}" ]]; then
        EXTRA_OPTIONS+=("--ssl-key=\"${MYSQL_SSL_KEY}\"")
    fi

    eval "mariadb-dump -h \"${MYSQL_HOST}\" -P \"${MYSQL_PORT}\" -u \"${MYSQL_USERNAME}\" -p\"${MYSQL_PASSWORD}\" ${EXTRA_OPTIONS[@]} \"${MYSQL_DATABASE}\" > \"${BACKUP_FILE_DB_MYSQL}\""
    if [[ $? != 0 ]]; then
        color red "backup vaultwarden mysql database failed"

        send_notification "failure" "Backup failed at $(date +"%Y-%m-%d %H:%M:%S %Z"). Reason: Backup mysql database failed."

        exit 1
    fi
}

function backup_config() {
    color blue "backup vaultwarden config"

    if [[ -f "${DATA_CONFIG}" ]]; then
        cp -f "${DATA_CONFIG}" "${BACKUP_FILE_CONFIG}"
    else
        color yellow "not found vaultwarden config, skipping"
    fi
}

function backup_rsakey() {
    color blue "backup vaultwarden rsakey"

    local FIND_RSAKEY=$(find "${DATA_RSAKEY_DIRNAME}" -name "${DATA_RSAKEY_BASENAME}*" | xargs -I {} basename {})
    local FIND_RSAKEY_COUNT=$(echo "${FIND_RSAKEY}" | wc -l)

    if [[ "${FIND_RSAKEY_COUNT}" -gt 0 ]]; then
        echo "${FIND_RSAKEY}" | tar -c -C "${DATA_RSAKEY_DIRNAME}" -f "${BACKUP_FILE_RSAKEY}" -T -

        color blue "display rsakey tar file list"

        tar -tf "${BACKUP_FILE_RSAKEY}"
    else
        color yellow "not found vaultwarden rsakey, skipping"
    fi
}

function backup_attachments() {
    color blue "backup vaultwarden attachments"

    if [[ -d "${DATA_ATTACHMENTS}" ]]; then
        tar -c -C "${DATA_ATTACHMENTS_DIRNAME}" -f "${BACKUP_FILE_ATTACHMENTS}" "${DATA_ATTACHMENTS_BASENAME}"

        color blue "display attachments tar file list"

        tar -tf "${BACKUP_FILE_ATTACHMENTS}"
    else
        color yellow "not found vaultwarden attachments directory, skipping"
    fi
}

function backup_sends() {
    color blue "backup vaultwarden sends"

    if [[ -d "${DATA_SENDS}" ]]; then
        tar -c -C "${DATA_SENDS_DIRNAME}" -f "${BACKUP_FILE_SENDS}" "${DATA_SENDS_BASENAME}"

        color blue "display sends tar file list"

        tar -tf "${BACKUP_FILE_SENDS}"
    else
        color yellow "not found vaultwarden sends directory, skipping"
    fi
}

function backup_json_export() {
    if [[ "${BW_EXPORT_ENABLE}" != "TRUE" ]]; then
        return
    fi

    color blue "backup vaultwarden vault export (${BW_EXPORT_FORMAT})"

    if [[ -z "${BW_SERVER_URL}" ]]; then
        color red "BW_SERVER_URL is required when BW_EXPORT_ENABLE is TRUE"
        send_notification "failure" "Backup failed at $(date +"%Y-%m-%d %H:%M:%S %Z"). Reason: BW_SERVER_URL is required."
        exit 1
    fi

    if [[ -z "${BW_CLIENTID}" || -z "${BW_CLIENTSECRET}" ]]; then
        color red "BW_CLIENTID and BW_CLIENTSECRET are required when BW_EXPORT_ENABLE is TRUE"
        send_notification "failure" "Backup failed at $(date +"%Y-%m-%d %H:%M:%S %Z"). Reason: BW_CLIENTID and BW_CLIENTSECRET are required."
        exit 1
    fi

    if [[ -z "${BW_PASSWORD}" ]]; then
        color red "BW_PASSWORD is required when BW_EXPORT_ENABLE is TRUE"
        send_notification "failure" "Backup failed at $(date +"%Y-%m-%d %H:%M:%S %Z"). Reason: BW_PASSWORD is required."
        exit 1
    fi

    # Configure server
    bw config server "${BW_SERVER_URL}" > /dev/null
    if [[ $? != 0 ]]; then
        color red "failed to configure Bitwarden server URL: ${BW_SERVER_URL}"
        send_notification "failure" "Backup failed at $(date +"%Y-%m-%d %H:%M:%S %Z"). Reason: Failed to configure Bitwarden server URL."
        exit 1
    fi

    # Login with API key
    BW_CLIENTID="${BW_CLIENTID}" BW_CLIENTSECRET="${BW_CLIENTSECRET}" bw login --apikey > /dev/null
    if [[ $? != 0 ]]; then
        color red "Bitwarden API login failed"
        send_notification "failure" "Backup failed at $(date +"%Y-%m-%d %H:%M:%S %Z"). Reason: Bitwarden API login failed."
        bw logout > /dev/null 2>&1 || true
        rm -rf "${HOME}/.config/Bitwarden CLI" 2>/dev/null || true
        exit 1
    fi

    # Unlock vault
    local BW_SESSION
    BW_SESSION="$(bw unlock --passwordenv BW_PASSWORD --raw 2>/dev/null)"
    if [[ $? != 0 || -z "${BW_SESSION}" ]]; then
        color red "Bitwarden unlock failed"
        send_notification "failure" "Backup failed at $(date +"%Y-%m-%d %H:%M:%S %Z"). Reason: Bitwarden vault unlock failed."
        bw logout > /dev/null 2>&1 || true
        rm -rf "${HOME}/.config/Bitwarden CLI" 2>/dev/null || true
        exit 1
    fi

    # Sync
    bw sync --session "${BW_SESSION}" > /dev/null 2>&1

    # Export
    local EXTRA_EXPORT_ARGS=()
    if [[ -n "${BW_ORGANIZATION_ID}" ]]; then
        EXTRA_EXPORT_ARGS+=("--organizationid" "${BW_ORGANIZATION_ID}")
    fi

    if [[ "${BW_EXPORT_FORMAT}" == "encrypted_json" ]]; then
        EXTRA_EXPORT_ARGS+=("--format" "encrypted_json" "--passwordenv" "BW_PASSWORD")
    elif [[ "${BW_EXPORT_FORMAT}" == "csv" ]]; then
        EXTRA_EXPORT_ARGS+=("--format" "csv")
    else
        EXTRA_EXPORT_ARGS+=("--format" "json")
    fi

    bw export --session "${BW_SESSION}" --output "${BACKUP_FILE_JSON_EXPORT}" "${EXTRA_EXPORT_ARGS[@]}" > /dev/null 2>&1
    local EXPORT_RESULT=$?

    # Logout and cleanup credentials immediately
    bw logout > /dev/null 2>&1 || true
    rm -rf "${HOME}/.config/Bitwarden CLI" 2>/dev/null || true

    if [[ ${EXPORT_RESULT} != 0 || ! -f "${BACKUP_FILE_JSON_EXPORT}" ]]; then
        color red "Bitwarden export failed"
        send_notification "failure" "Backup failed at $(date +"%Y-%m-%d %H:%M:%S %Z"). Reason: Bitwarden export failed."
        exit 1
    fi

    color green "Bitwarden vault export successful"
}

function backup() {
    mkdir -p "${BACKUP_DIR}"

    case "${DB_TYPE}" in
        SQLITE)     backup_db_sqlite ;;
        POSTGRESQL) backup_db_postgresql ;;
        MYSQL)      backup_db_mysql ;;
    esac

    backup_config
    backup_rsakey
    backup_attachments
    backup_sends
    backup_json_export

    ls -lah "${BACKUP_DIR}"
}

function backup_package() {
    if [[ "${ZIP_ENABLE}" == "TRUE" ]]; then
        color blue "package backup file"

        UPLOAD_FILE="${BACKUP_FILE_ZIP}"

        if [[ "${ZIP_TYPE}" == "zip" ]]; then
            7z a -tzip -mx=9 -p"${ZIP_PASSWORD}" "${BACKUP_FILE_ZIP}" "${BACKUP_DIR}"/*
        else
            7z a -t7z -m0=lzma2 -mx=9 -mfb=64 -md=32m -ms=on -mhe=on -p"${ZIP_PASSWORD}" "${BACKUP_FILE_ZIP}" "${BACKUP_DIR}"/*
        fi

        ls -lah "${BACKUP_DIR}"

        color blue "display backup ${ZIP_TYPE} file list"

        7z l -p"${ZIP_PASSWORD}" "${BACKUP_FILE_ZIP}"
    else
        color yellow "skip package backup files"

        UPLOAD_FILE="${BACKUP_DIR}"
    fi
}

function upload() {
    # upload file not exist
    if [[ ! -e "${UPLOAD_FILE}" ]]; then
        color red "upload file not found"

        send_notification "failure" "File upload failed at $(date +"%Y-%m-%d %H:%M:%S %Z"). Reason: Upload file not found."

        exit 1
    fi

    # upload
    local HAS_ERROR="FALSE"

    for RCLONE_REMOTE_X in "${RCLONE_REMOTE_LIST[@]}"
    do
        color blue "upload backup file to storage system $(color yellow "[${RCLONE_REMOTE_X}]")"

        rclone ${RCLONE_GLOBAL_FLAG} copy "${UPLOAD_FILE}" "${RCLONE_REMOTE_X}"
        if [[ $? != 0 ]]; then
            color red "upload failed"

            HAS_ERROR="TRUE"
        fi
    done

    if [[ "${HAS_ERROR}" == "TRUE" ]]; then
        send_notification "failure" "File upload failed at $(date +"%Y-%m-%d %H:%M:%S %Z")."

        exit 1
    fi
}

function clear_history() {
    if [[ "${BACKUP_KEEP_DAYS}" -gt 0 ]]; then
        for RCLONE_REMOTE_X in "${RCLONE_REMOTE_LIST[@]}"
        do
            color blue "delete ${BACKUP_KEEP_DAYS} days ago backup files $(color yellow "[${RCLONE_REMOTE_X}]")"

            mapfile -t RCLONE_DELETE_LIST < <(rclone ${RCLONE_GLOBAL_FLAG} lsf "${RCLONE_REMOTE_X}" --min-age "${BACKUP_KEEP_DAYS}d")

            for RCLONE_DELETE_FILE in "${RCLONE_DELETE_LIST[@]}"
            do
                color yellow "deleting \"${RCLONE_DELETE_FILE}\""

                rclone ${RCLONE_GLOBAL_FLAG} delete "${RCLONE_REMOTE_X}/${RCLONE_DELETE_FILE}"
                if [[ $? != 0 ]]; then
                    color red "delete \"${RCLONE_DELETE_FILE}\" failed"
                fi
            done
        done
    fi
}

color blue "running the backup program at $(date +"%Y-%m-%d %H:%M:%S %Z")"

init_env

send_notification "start" "Start backup at $(date +"%Y-%m-%d %H:%M:%S %Z")"

check_rclone_connection any

clear_dir
backup_init
backup
backup_package
upload
clear_dir
clear_history

send_notification "success" "The file was successfully uploaded at $(date +"%Y-%m-%d %H:%M:%S %Z")."

color none ""
