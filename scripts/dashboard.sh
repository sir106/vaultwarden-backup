#!/bin/bash

. /app/includes.sh

DASHBOARD_ROOT="/tmp/vaultwarden-dashboard"
DASHBOARD_WWW_DIR="${DASHBOARD_ROOT}/www"
DASHBOARD_CGI_DIR="${DASHBOARD_WWW_DIR}/cgi-bin"
DASHBOARD_STATE_DIR="${DASHBOARD_ROOT}/state"
DASHBOARD_ACTIVITY_LOG="/config/dashboard-activity.log"
DASHBOARD_DRY_RUN_TTL_SECONDS="600"
DASHBOARD_MAX_RECENT_DEFAULT="30"

function json_escape() {
    echo -n "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

function url_decode() {
    local VALUE="${1//+/ }"
    printf '%b' "${VALUE//%/\\x}"
}

function get_query_param() {
    local KEY="$1"
    local QUERY="${QUERY_STRING:-}"
    local ITEM

    IFS='&' read -ra QUERY_ITEMS <<< "${QUERY}"
    for ITEM in "${QUERY_ITEMS[@]}"; do
        local ITEM_KEY="${ITEM%%=*}"
        local ITEM_VALUE="${ITEM#*=}"

        if [[ "${ITEM_KEY}" == "${KEY}" ]]; then
            url_decode "${ITEM_VALUE}"
            return
        fi
    done

    echo -n ""
}

function read_form_param() {
    local KEY="$1"
    local BODY="$2"
    local ITEM

    IFS='&' read -ra BODY_ITEMS <<< "${BODY}"
    for ITEM in "${BODY_ITEMS[@]}"; do
        local ITEM_KEY="${ITEM%%=*}"
        local ITEM_VALUE="${ITEM#*=}"

        if [[ "${ITEM_KEY}" == "${KEY}" ]]; then
            url_decode "${ITEM_VALUE}"
            return
        fi
    done

    echo -n ""
}

function read_request_body() {
    local BODY=""

    if [[ "${REQUEST_METHOD}" == "POST" ]]; then
        if [[ -n "${CONTENT_LENGTH}" && "${CONTENT_LENGTH}" -gt 0 ]]; then
            read -r -n "${CONTENT_LENGTH}" BODY
        fi
    fi

    echo -n "${BODY}"
}

function send_response() {
    local STATUS="$1"
    local CONTENT_TYPE="$2"
    local BODY="$3"

    echo "Status: ${STATUS}"
    echo "Content-Type: ${CONTENT_TYPE}"
    echo "Cache-Control: no-store"
    echo ""
    echo -n "${BODY}"
}

function send_json() {
    send_response "$1" "application/json" "$2"
}

function send_html() {
    send_response "$1" "text/html; charset=utf-8" "$2"
}

function send_unauthorized() {
    send_response "401 Unauthorized" "application/json" '{"ok":false,"error":"unauthorized"}'
}

function send_not_found() {
    send_response "404 Not Found" "application/json" '{"ok":false,"error":"not_found"}'
}

function append_activity_log() {
    local EVENT="$1"
    local DETAIL="$2"
    local TS

    TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    mkdir -p "$(dirname "${DASHBOARD_ACTIVITY_LOG}")" > /dev/null 2>&1 || true

    {
        printf '{"time":"%s","event":"%s","detail":"%s"}\n' "$(json_escape "${TS}")" "$(json_escape "${EVENT}")" "$(json_escape "${DETAIL}")"
    } >> "${DASHBOARD_ACTIVITY_LOG}" 2> /dev/null || true
}

function check_admin_token_match() {
    local PROVIDED="$1"
    local STORED="$2"

    if [[ -z "${PROVIDED}" || -z "${STORED}" ]]; then
        return 1
    fi

    # Trim leading/trailing whitespace
    PROVIDED="$(echo -n "${PROVIDED}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    STORED="$(echo -n "${STORED}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    # Strip surrounding single or double quotes if present (e.g. ADMIN_TOKEN='$argon2id$...')
    if [[ "${STORED}" =~ ^\'(.*)\'$ || "${STORED}" =~ ^\"(.*)\"$ ]]; then
        STORED="${BASH_REMATCH[1]}"
    fi

    # Unescape double $$ if configured in docker-compose YAML
    STORED="${STORED//\$\$/\$}"

    # Exact match (for plain text token or direct hash match)
    if [[ "${PROVIDED}" == "${STORED}" ]]; then
        return 0
    fi

    # If STORED is an Argon2 PHC hash ($argon2id$, $argon2i$, $argon2d$)
    if [[ "${STORED}" =~ ^\$argon2 ]]; then
        if python3 -c '
import sys
try:
    import argon2
    stored = sys.argv[1]
    provided = sys.argv[2]
    try:
        ph = argon2.PasswordHasher()
        ph.verify(stored, provided)
        sys.exit(0)
    except Exception:
        argon2.low_level.verify_secret(stored.encode("ascii"), provided.encode("utf-8"), argon2.Type.ID)
        sys.exit(0)
except Exception:
    sys.exit(1)
' "${STORED}" "${PROVIDED}" 2> /dev/null; then
            return 0
        fi
    fi

    return 1
}

function require_admin_token() {
    local PROVIDED_TOKEN=""

    if [[ -n "${HTTP_X_ADMIN_TOKEN}" ]]; then
        PROVIDED_TOKEN="${HTTP_X_ADMIN_TOKEN}"
    elif [[ "${HTTP_AUTHORIZATION}" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then
        PROVIDED_TOKEN="${BASH_REMATCH[1]}"
    fi

    if [[ -z "${DASHBOARD_ADMIN_TOKEN}" ]]; then
        append_activity_log "auth_rejected" "admin token is not configured"
        return 1
    fi

    if ! check_admin_token_match "${PROVIDED_TOKEN}" "${DASHBOARD_ADMIN_TOKEN}"; then
        append_activity_log "auth_rejected" "invalid or missing token"
        return 1
    fi

    return 0
}

function is_supported_backup_file() {
    case "$1" in
        backup.*.zip|backup.*.7z|backup*.zip|backup*.7z|db.*.sqlite3|db.*.dump|db.*.sql|config.*.json|rsakey.*.tar|attachments.*.tar|sends.*.tar)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

function detect_restore_flag() {
    case "$1" in
        backup.*.zip|backup.*.7z|backup*.zip|backup*.7z) echo -n "--zip-file" ;;
        db.*.sqlite3|db.*.dump|db.*.sql) echo -n "--db-file" ;;
        config.*.json) echo -n "--config-file" ;;
        rsakey.*.tar) echo -n "--rsakey-file" ;;
        attachments.*.tar) echo -n "--attachments-file" ;;
        sends.*.tar) echo -n "--sends-file" ;;
        *) echo -n "" ;;
    esac
}

function remote_exists_in_list() {
    local REMOTE="$1"
    local CURRENT

    for CURRENT in "${RCLONE_REMOTE_LIST[@]}"; do
        if [[ "${CURRENT}" == "${REMOTE}" ]]; then
            return 0
        fi
    done

    return 1
}

function create_id() {
    echo -n "$(date +%s%N)-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
}

function dry_run_file_path() {
    echo -n "${DASHBOARD_STATE_DIR}/dry-run-$1.env"
}

function restore_status_path() {
    echo -n "${DASHBOARD_STATE_DIR}/restore-$1.env"
}

function restore_log_path() {
    echo -n "${DASHBOARD_STATE_DIR}/restore-$1.log"
}

function write_restore_status() {
    local ID="$1"
    local STATUS="$2"
    local MESSAGE="$3"
    local FILE="$4"
    local REMOTE="$5"
    local UPDATED_AT

    UPDATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    cat > "$(restore_status_path "${ID}")" <<EOF
id=${ID}
status=${STATUS}
message=$(echo -n "${MESSAGE}" | tr '\n' ' ')
file=${FILE}
remote=${REMOTE}
updated_at=${UPDATED_AT}
EOF
}

function read_restore_status_json() {
    local ID="$1"
    local STATUS_FILE
    local LOG_FILE

    STATUS_FILE="$(restore_status_path "${ID}")"
    LOG_FILE="$(restore_log_path "${ID}")"

    if [[ ! -f "${STATUS_FILE}" ]]; then
        echo -n '{"ok":false,"error":"status_not_found"}'
        return
    fi

    local ID_VALUE=""
    local STATUS_VALUE=""
    local MESSAGE_VALUE=""
    local FILE_VALUE=""
    local REMOTE_VALUE=""
    local UPDATED_AT_VALUE=""
    local LAST_LOG_LINE=""

    while IFS='=' read -r KEY VALUE; do
        case "${KEY}" in
            id) ID_VALUE="${VALUE}" ;;
            status) STATUS_VALUE="${VALUE}" ;;
            message) MESSAGE_VALUE="${VALUE}" ;;
            file) FILE_VALUE="${VALUE}" ;;
            remote) REMOTE_VALUE="${VALUE}" ;;
            updated_at) UPDATED_AT_VALUE="${VALUE}" ;;
        esac
    done < "${STATUS_FILE}"

    if [[ -f "${LOG_FILE}" ]]; then
        LAST_LOG_LINE="$(tail -n 1 "${LOG_FILE}" 2> /dev/null)"
    fi

    printf '{"ok":true,"id":"%s","status":"%s","message":"%s","file":"%s","remote":"%s","updated_at":"%s","last_log":"%s"}' \
      "$(json_escape "${ID_VALUE}")" \
      "$(json_escape "${STATUS_VALUE}")" \
      "$(json_escape "${MESSAGE_VALUE}")" \
      "$(json_escape "${FILE_VALUE}")" \
      "$(json_escape "${REMOTE_VALUE}")" \
      "$(json_escape "${UPDATED_AT_VALUE}")" \
      "$(json_escape "${LAST_LOG_LINE}")"
}

function list_recent_backups_json() {
    local LIMIT_RAW="$1"
    local LIMIT

    LIMIT="${LIMIT_RAW:-${DASHBOARD_MAX_RECENT_DEFAULT}}"
    if ! [[ "${LIMIT}" =~ ^[0-9]+$ ]]; then
        LIMIT="${DASHBOARD_MAX_RECENT_DEFAULT}"
    fi
    if [[ "${LIMIT}" -lt 1 ]]; then
        LIMIT="${DASHBOARD_MAX_RECENT_DEFAULT}"
    fi
    if [[ "${LIMIT}" -gt 200 ]]; then
        LIMIT="200"
    fi

    local TMP_LINES
    TMP_LINES="$(mktemp)"

    local REMOTE
    for REMOTE in "${RCLONE_REMOTE_LIST[@]}"; do
        mapfile -t LIST_LINES < <(rclone ${RCLONE_GLOBAL_FLAG} lsf "${REMOTE}" --files-only --format "pst" --separator "|" 2> /dev/null)

        local LINE
        for LINE in "${LIST_LINES[@]}"; do
            local FILE_NAME="${LINE%%|*}"
            local REST="${LINE#*|}"
            local FILE_SIZE="${REST%%|*}"
            local FILE_MODIFIED="${REST#*|}"

            if ! is_supported_backup_file "${FILE_NAME}"; then
                continue
            fi

            local MODIFIED_EPOCH
            MODIFIED_EPOCH="$(date -d "${FILE_MODIFIED}" +%s 2> /dev/null || echo "0")"

            printf '%s|%s|%s|%s|%s\n' "${MODIFIED_EPOCH}" "${REMOTE}" "${FILE_NAME}" "${FILE_SIZE}" "${FILE_MODIFIED}" >> "${TMP_LINES}"
        done
    done

    local RESULT='{"ok":true,"items":['
    local FIRST="TRUE"

    if [[ -f "${TMP_LINES}" ]]; then
        while IFS='|' read -r _MOD_EPOCH REMOTE FILE_NAME FILE_SIZE FILE_MODIFIED; do
            if [[ -z "${FILE_NAME}" ]]; then
                continue
            fi
            if [[ "${FIRST}" == "TRUE" ]]; then
                FIRST="FALSE"
            else
                RESULT+=","
            fi

            RESULT+="{\"remote\":\"$(json_escape "${REMOTE}")\",\"file\":\"$(json_escape "${FILE_NAME}")\",\"size\":${FILE_SIZE:-0},\"modified\":\"$(json_escape "${FILE_MODIFIED}")\"}"
        done < <(sort -t '|' -k1,1nr "${TMP_LINES}" | head -n "${LIMIT}")
    fi

    RESULT+="]}"

    rm -f "${TMP_LINES}"

    echo -n "${RESULT}"
}

function handle_recent_backups() {
    local LIMIT

    LIMIT="$(get_query_param "limit")"
    append_activity_log "backups_recent" "limit=${LIMIT:-default}"

    send_json "200 OK" "$(list_recent_backups_json "${LIMIT}")"
}

function handle_restore_dry_run() {
    if [[ "${REQUEST_METHOD}" != "POST" ]]; then
        send_json "405 Method Not Allowed" '{"ok":false,"error":"method_not_allowed"}'
        return
    fi

    local BODY
    local REMOTE
    local FILE_NAME
    local RESTORE_FLAG

    BODY="$(read_request_body)"
    REMOTE="$(read_form_param "remote" "${BODY}")"
    FILE_NAME="$(read_form_param "file" "${BODY}")"

    if [[ -z "${REMOTE}" || -z "${FILE_NAME}" ]]; then
        send_json "400 Bad Request" '{"ok":false,"error":"missing_remote_or_file"}'
        return
    fi

    if [[ "${FILE_NAME}" != "$(basename "${FILE_NAME}")" ]]; then
        send_json "400 Bad Request" '{"ok":false,"error":"invalid_file_name"}'
        return
    fi

    if ! remote_exists_in_list "${REMOTE}"; then
        send_json "400 Bad Request" '{"ok":false,"error":"unknown_remote"}'
        return
    fi

    if ! is_supported_backup_file "${FILE_NAME}"; then
        send_json "400 Bad Request" '{"ok":false,"error":"unsupported_file_type"}'
        return
    fi

    RESTORE_FLAG="$(detect_restore_flag "${FILE_NAME}")"
    if [[ -z "${RESTORE_FLAG}" ]]; then
        send_json "400 Bad Request" '{"ok":false,"error":"restore_flag_not_found"}'
        return
    fi

    rclone ${RCLONE_GLOBAL_FLAG} lsf "${REMOTE}" --files-only --include "${FILE_NAME}" 2> /dev/null | grep -Fx "${FILE_NAME}" > /dev/null
    if [[ $? != 0 ]]; then
        send_json "404 Not Found" '{"ok":false,"error":"backup_file_not_found"}'
        return
    fi

    local DRY_RUN_ID
    local CREATED_AT

    DRY_RUN_ID="$(create_id)"
    CREATED_AT="$(date +%s)"

    cat > "$(dry_run_file_path "${DRY_RUN_ID}")" <<EOF
id=${DRY_RUN_ID}
created_at=${CREATED_AT}
remote=${REMOTE}
file=${FILE_NAME}
restore_flag=${RESTORE_FLAG}
EOF

    append_activity_log "restore_dry_run" "id=${DRY_RUN_ID};remote=${REMOTE};file=${FILE_NAME}"

    local RESPONSE_JSON
    RESPONSE_JSON=$(printf '{"ok":true,"dry_run_id":"%s","remote":"%s","file":"%s","restore_flag":"%s"}' \
      "$(json_escape "${DRY_RUN_ID}")" \
      "$(json_escape "${REMOTE}")" \
      "$(json_escape "${FILE_NAME}")" \
      "$(json_escape "${RESTORE_FLAG}")")

    send_json "200 OK" "${RESPONSE_JSON}"
}

function run_restore_job() {
    local RESTORE_ID="$1"
    local DRY_RUN_ID="$2"
    local ZIP_PASSWORD_VALUE="$3"

    local DRY_RUN_FILE
    DRY_RUN_FILE="$(dry_run_file_path "${DRY_RUN_ID}")"

    if [[ ! -f "${DRY_RUN_FILE}" ]]; then
        write_restore_status "${RESTORE_ID}" "failed" "dry-run file missing" "" ""
        return
    fi

    # shellcheck disable=SC1090
    source "${DRY_RUN_FILE}"

    local RESTORE_TARGET_FILE="${RESTORE_DIR}/${file}"
    local LOG_FILE

    LOG_FILE="$(restore_log_path "${RESTORE_ID}")"

    write_restore_status "${RESTORE_ID}" "running" "restore started" "${file}" "${remote}"

    {
        echo "[dashboard] creating restore directory: ${RESTORE_DIR}"
        mkdir -p "${RESTORE_DIR}"

        echo "[dashboard] downloading ${file} from ${remote}"
        rclone ${RCLONE_GLOBAL_FLAG} copyto "${remote}/${file}" "${RESTORE_TARGET_FILE}"
        if [[ $? != 0 ]]; then
            echo "[dashboard] download failed"
            write_restore_status "${RESTORE_ID}" "failed" "download failed" "${file}" "${remote}"
            append_activity_log "restore_execute_failed" "id=${RESTORE_ID};reason=download_failed"
            return 1
        fi

        echo "[dashboard] executing restore"
        local RESTORE_CMD=()
        local EFFECTIVE_PASSWORD="${ZIP_PASSWORD_VALUE:-"${ZIP_PASSWORD}"}"
        if [[ -n "${EFFECTIVE_PASSWORD}" && "${restore_flag}" == "--zip-file" ]]; then
            RESTORE_CMD=(bash /app/entrypoint.sh restore -f -p "${EFFECTIVE_PASSWORD}" "${restore_flag}" "${file}")
        else
            RESTORE_CMD=(bash /app/entrypoint.sh restore -f "${restore_flag}" "${file}")
        fi

        "${RESTORE_CMD[@]}"
        local RESTORE_EXIT_CODE=$?

        if [[ ${RESTORE_EXIT_CODE} != 0 ]]; then
            echo "[dashboard] restore failed with exit code ${RESTORE_EXIT_CODE}"
            write_restore_status "${RESTORE_ID}" "failed" "restore command failed (exit code ${RESTORE_EXIT_CODE})" "${file}" "${remote}"
            append_activity_log "restore_execute_failed" "id=${RESTORE_ID};reason=restore_failed"
            return 1
        fi

        echo "[dashboard] restore completed successfully"
        write_restore_status "${RESTORE_ID}" "success" "restore completed" "${file}" "${remote}"
        append_activity_log "restore_execute_success" "id=${RESTORE_ID};remote=${remote};file=${file}"
    } >> "${LOG_FILE}" 2>&1
}

function handle_restore_execute() {
    if [[ "${REQUEST_METHOD}" != "POST" ]]; then
        send_json "405 Method Not Allowed" '{"ok":false,"error":"method_not_allowed"}'
        return
    fi

    local BODY
    local DRY_RUN_ID
    local FORCE_RESTORE_VALUE
    local ZIP_PASSWORD_VALUE

    BODY="$(read_request_body)"
    DRY_RUN_ID="$(read_form_param "dry_run_id" "${BODY}")"
    FORCE_RESTORE_VALUE="$(read_form_param "force" "${BODY}")"
    ZIP_PASSWORD_VALUE="$(read_form_param "password" "${BODY}")"

    if [[ -z "${DRY_RUN_ID}" ]]; then
        send_json "400 Bad Request" '{"ok":false,"error":"missing_dry_run_id"}'
        return
    fi

    if [[ "${FORCE_RESTORE_VALUE,,}" != "true" ]]; then
        send_json "400 Bad Request" '{"ok":false,"error":"force_must_be_true"}'
        return
    fi

    local DRY_RUN_FILE
    DRY_RUN_FILE="$(dry_run_file_path "${DRY_RUN_ID}")"

    if [[ ! -f "${DRY_RUN_FILE}" ]]; then
        send_json "404 Not Found" '{"ok":false,"error":"dry_run_not_found"}'
        return
    fi

    # shellcheck disable=SC1090
    source "${DRY_RUN_FILE}"

    local NOW_EPOCH
    NOW_EPOCH="$(date +%s)"

    if [[ -z "${created_at}" || $((NOW_EPOCH - created_at)) -gt ${DASHBOARD_DRY_RUN_TTL_SECONDS} ]]; then
        send_json "400 Bad Request" '{"ok":false,"error":"dry_run_expired"}'
        return
    fi

    local RESTORE_ID
    RESTORE_ID="$(create_id)"

    write_restore_status "${RESTORE_ID}" "queued" "restore queued" "${file}" "${remote}"

    run_restore_job "${RESTORE_ID}" "${DRY_RUN_ID}" "${ZIP_PASSWORD_VALUE}" &

    append_activity_log "restore_execute" "id=${RESTORE_ID};dry_run_id=${DRY_RUN_ID};remote=${remote};file=${file}"

    local RESPONSE_JSON
    RESPONSE_JSON=$(printf '{"ok":true,"restore_id":"%s","status":"queued"}' "$(json_escape "${RESTORE_ID}")")

    send_json "200 OK" "${RESPONSE_JSON}"
}

function handle_restore_status() {
    local RESTORE_ID

    RESTORE_ID="$(get_query_param "id")"

    if [[ -z "${RESTORE_ID}" ]]; then
        send_json "400 Bad Request" '{"ok":false,"error":"missing_id"}'
        return
    fi

    send_json "200 OK" "$(read_restore_status_json "${RESTORE_ID}")"
}

function dashboard_ui_html() {
cat <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Vaultwarden Backup Dashboard</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0f172a;
      --card-bg: #1e293b;
      --card-border: #334155;
      --text-main: #f8fafc;
      --text-muted: #94a3b8;
      --primary: #38bdf8;
      --primary-hover: #0ea5e9;
      --accent: #6366f1;
      --success: #10b981;
      --warning: #f59e0b;
      --danger: #ef4444;
      --code-bg: #0b0f19;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: 'Inter', system-ui, -apple-system, sans-serif;
      color: var(--text-main);
      background-color: var(--bg);
      background-image:
        radial-gradient(at 0% 0%, rgba(56, 189, 248, 0.12) 0px, transparent 50%),
        radial-gradient(at 100% 100%, rgba(99, 102, 241, 0.12) 0px, transparent 50%);
      min-height: 100vh;
      padding: 24px 16px;
    }
    .container {
      max-width: 1080px;
      margin: 0 auto;
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 16px;
      margin-bottom: 24px;
      padding-bottom: 20px;
      border-bottom: 1px solid var(--card-border);
    }
    .header h1 {
      margin: 0;
      font-size: 24px;
      font-weight: 700;
      background: linear-gradient(135deg, #38bdf8, #818cf8);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }
    .header p {
      margin: 4px 0 0;
      color: var(--text-muted);
      font-size: 14px;
    }
    .card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 12px;
      padding: 20px;
      margin-bottom: 20px;
      box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.3);
    }
    .card-title {
      font-size: 16px;
      font-weight: 600;
      margin-top: 0;
      margin-bottom: 14px;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .auth-bar {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      align-items: center;
    }
    input[type="text"], input[type="password"], select {
      background: var(--code-bg);
      border: 1px solid var(--card-border);
      color: var(--text-main);
      border-radius: 8px;
      padding: 10px 14px;
      font-size: 14px;
      outline: none;
      transition: border-color 0.2s;
    }
    input[type="text"]:focus, input[type="password"]:focus {
      border-color: var(--primary);
    }
    .flex-1 { flex: 1; min-width: 240px; }
    button {
      background: var(--primary);
      color: #0f172a;
      border: none;
      border-radius: 8px;
      padding: 10px 18px;
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      transition: all 0.2s;
    }
    button:hover {
      background: var(--primary-hover);
      box-shadow: 0 0 12px rgba(56, 189, 248, 0.4);
    }
    button.secondary {
      background: #334155;
      color: #f8fafc;
    }
    button.secondary:hover {
      background: #475569;
      box-shadow: none;
    }
    button.danger {
      background: var(--danger);
      color: #ffffff;
    }
    button.danger:hover {
      background: #dc2626;
      box-shadow: 0 0 12px rgba(239, 68, 68, 0.4);
    }
    .table-container {
      overflow-x: auto;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 14px;
    }
    th {
      text-align: left;
      padding: 12px 10px;
      color: var(--text-muted);
      border-bottom: 1px solid var(--card-border);
      font-weight: 500;
    }
    td {
      padding: 12px 10px;
      border-bottom: 1px solid rgba(51, 65, 85, 0.5);
    }
    tr:hover td {
      background: rgba(255, 255, 255, 0.02);
    }
    .badge {
      display: inline-block;
      padding: 3px 8px;
      border-radius: 6px;
      font-size: 12px;
      font-weight: 600;
    }
    .badge-queued { background: #334155; color: #94a3b8; }
    .badge-running { background: rgba(56, 189, 248, 0.2); color: #38bdf8; }
    .badge-success { background: rgba(16, 185, 129, 0.2); color: #10b981; }
    .badge-failed { background: rgba(239, 68, 68, 0.2); color: #ef4444; }
    .status-box {
      background: var(--code-bg);
      border: 1px solid var(--card-border);
      border-radius: 8px;
      padding: 14px;
      font-family: 'JetBrains Mono', monospace;
      font-size: 13px;
      color: #cbd5e1;
      white-space: pre-wrap;
      word-break: break-all;
      max-height: 250px;
      overflow-y: auto;
    }
    .grid-2 {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 16px;
    }
    @media (max-width: 768px) {
      .grid-2 { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div>
        <h1>Vaultwarden Backup Dashboard</h1>
        <p>Review remote backups, run validation checks, and execute restores safely.</p>
      </div>
      <div id="authStatus" class="badge badge-queued">Not Authenticated</div>
    </div>

    <!-- Auth Card -->
    <div class="card">
      <div class="card-title">🔑 Authentication</div>
      <div class="auth-bar">
        <input id="tokenInput" type="password" class="flex-1" placeholder="Enter Vaultwarden ADMIN_TOKEN" />
        <button id="saveTokenBtn" class="secondary">Save Token</button>
        <button id="clearTokenBtn" class="secondary">Clear</button>
        <button id="loadBackupsBtn">🔄 Load Backups</button>
      </div>
    </div>

    <!-- Backups List Card -->
    <div class="card">
      <div class="card-title">📦 Recent Remote Backups</div>
      <div class="table-container">
        <table>
          <thead>
            <tr>
              <th>Remote</th>
              <th>Backup File</th>
              <th>Size</th>
              <th>Modified</th>
              <th>Action</th>
            </tr>
          </thead>
          <tbody id="backupRows">
            <tr>
              <td colspan="5" style="text-align: center; color: var(--text-muted); padding: 24px;">
                Enter your ADMIN_TOKEN above and click "Load Backups".
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <div class="grid-2">
      <!-- Dry-Run & Execute Card -->
      <div class="card">
        <div class="card-title">🚀 Restore Control</div>
        <div style="display:flex; flex-direction:column; gap:12px;">
          <div>
            <label style="font-size:12px; color:var(--text-muted); display:block; margin-bottom:4px;">Selected Dry-Run ID</label>
            <input id="dryRunIdInput" type="text" style="width:100%" placeholder="Generated from Dry Run action" />
          </div>
          <div>
            <label style="font-size:12px; color:var(--text-muted); display:block; margin-bottom:4px;">ZIP / 7Z Password (if encrypted)</label>
            <input id="zipPasswordInput" type="password" style="width:100%" placeholder="Optional archive password" />
          </div>
          <div style="margin-top:8px;">
            <button id="executeRestoreBtn" class="danger" style="width:100%">⚠️ Execute Restore</button>
          </div>
        </div>
      </div>

      <!-- Status & Activity Card -->
      <div class="card">
        <div class="card-title">
          <span>📊 Status & Logs</span>
          <span id="jobBadge" class="badge badge-queued" style="margin-left:auto;">Idle</span>
        </div>
        <div style="display:flex; gap:8px; margin-bottom:12px;">
          <input id="restoreIdInput" type="text" class="flex-1" placeholder="Restore Task ID" />
          <button id="checkStatusBtn" class="secondary">Check</button>
        </div>
        <div id="statusBox" class="status-box">Status updates and logs will appear here.</div>
      </div>
    </div>
  </div>

  <script>
    const tokenInput = document.getElementById('tokenInput');
    const saveTokenBtn = document.getElementById('saveTokenBtn');
    const clearTokenBtn = document.getElementById('clearTokenBtn');
    const loadBackupsBtn = document.getElementById('loadBackupsBtn');
    const authStatus = document.getElementById('authStatus');
    const backupRows = document.getElementById('backupRows');
    const dryRunIdInput = document.getElementById('dryRunIdInput');
    const zipPasswordInput = document.getElementById('zipPasswordInput');
    const executeRestoreBtn = document.getElementById('executeRestoreBtn');
    const restoreIdInput = document.getElementById('restoreIdInput');
    const checkStatusBtn = document.getElementById('checkStatusBtn');
    const statusBox = document.getElementById('statusBox');
    const jobBadge = document.getElementById('jobBadge');

    let pollInterval = null;

    function formatBytes(bytes) {
      if (!bytes || bytes === 0) return '0 B';
      const k = 1024;
      const sizes = ['B', 'KB', 'MB', 'GB'];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    }

    function getToken() {
      return tokenInput.value.trim();
    }

    function authHeaders() {
      return {
        'X-Admin-Token': getToken()
      };
    }

    function log(msg) {
      const ts = new Date().toLocaleTimeString();
      statusBox.textContent = `[${ts}] ${msg}\n` + statusBox.textContent;
    }

    function loadSavedToken() {
      const saved = localStorage.getItem('vw_dashboard_token');
      if (saved) {
        tokenInput.value = saved;
        authStatus.textContent = 'Token Loaded';
        authStatus.className = 'badge badge-success';
      }
    }

    saveTokenBtn.addEventListener('click', () => {
      const token = getToken();
      if (token) {
        localStorage.setItem('vw_dashboard_token', token);
        authStatus.textContent = 'Token Saved';
        authStatus.className = 'badge badge-success';
        log('Admin token saved to browser local storage.');
      }
    });

    clearTokenBtn.addEventListener('click', () => {
      localStorage.removeItem('vw_dashboard_token');
      tokenInput.value = '';
      authStatus.textContent = 'Token Cleared';
      authStatus.className = 'badge badge-queued';
      log('Admin token cleared.');
    });

    async function loadBackups() {
      const token = getToken();
      if (!token) {
        alert('Please enter an ADMIN_TOKEN first.');
        return;
      }

      backupRows.innerHTML = '<tr><td colspan="5" style="text-align:center; padding:20px;">Loading backups...</td></tr>';
      log('Fetching recent backups from rclone remotes...');

      try {
        const res = await fetch('/cgi-bin/api/backups/recent?limit=40', { headers: authHeaders() });
        const data = await res.json();

        if (!res.ok || !data.ok) {
          authStatus.textContent = 'Auth Failed';
          authStatus.className = 'badge badge-failed';
          backupRows.innerHTML = `<tr><td colspan="5" style="text-align:center; color:var(--danger); padding:20px;">Error: ${data.error || res.statusText}</td></tr>`;
          log(`Failed to fetch backups: ${data.error || res.status}`);
          return;
        }

        authStatus.textContent = 'Authenticated';
        authStatus.className = 'badge badge-success';

        if (!data.items || data.items.length === 0) {
          backupRows.innerHTML = '<tr><td colspan="5" style="text-align:center; padding:20px;">No backup files found.</td></tr>';
          log('No backup files found on remote(s).');
          return;
        }

        backupRows.innerHTML = '';
        data.items.forEach(item => {
          const tr = document.createElement('tr');
          tr.innerHTML = `
            <td><code>${item.remote}</code></td>
            <td><strong>${item.file}</strong></td>
            <td>${formatBytes(item.size)}</td>
            <td>${item.modified || '-'}</td>
            <td><button class="secondary dry-run-btn" data-remote="${item.remote}" data-file="${item.file}">🧪 Dry Run</button></td>
          `;
          tr.querySelector('.dry-run-btn').addEventListener('click', () => triggerDryRun(item.remote, item.file));
          backupRows.appendChild(tr);
        });

        log(`Successfully loaded ${data.items.length} backup file(s).`);
      } catch (err) {
        backupRows.innerHTML = `<tr><td colspan="5" style="text-align:center; color:var(--danger); padding:20px;">Network error: ${err.message}</td></tr>`;
        log(`Network error: ${err.message}`);
      }
    }

    async function triggerDryRun(remote, file) {
      log(`Starting dry-run validation for ${file} on remote ${remote}...`);
      try {
        const body = new URLSearchParams({ remote, file }).toString();
        const res = await fetch('/cgi-bin/api/restore/dry-run', {
          method: 'POST',
          headers: { ...authHeaders(), 'Content-Type': 'application/x-www-form-urlencoded' },
          body
        });
        const data = await res.json();

        if (!res.ok || !data.ok) {
          log(`Dry-run failed: ${data.error || res.status}`);
          alert(`Dry-run failed: ${data.error || res.status}`);
          return;
        }

        dryRunIdInput.value = data.dry_run_id;
        log(`✓ Dry-run succeeded! dry_run_id: ${data.dry_run_id} (Target restore flag: ${data.restore_flag})`);
      } catch (err) {
        log(`Dry-run error: ${err.message}`);
      }
    }

    async function executeRestore() {
      const dryRunId = dryRunIdInput.value.trim();
      const password = zipPasswordInput.value;

      if (!dryRunId) {
        alert('Please run a Dry-Run first to generate a valid dry_run_id.');
        return;
      }

      const confirmed = confirm('WARNING: Restoring will overwrite existing Vaultwarden data. Are you sure you want to proceed?');
      if (!confirmed) return;

      log(`Initiating restore job for dry_run_id: ${dryRunId}...`);
      try {
        const body = new URLSearchParams({
          dry_run_id: dryRunId,
          password: password,
          force: 'true'
        }).toString();

        const res = await fetch('/cgi-bin/api/restore/execute', {
          method: 'POST',
          headers: { ...authHeaders(), 'Content-Type': 'application/x-www-form-urlencoded' },
          body
        });
        const data = await res.json();

        if (!res.ok || !data.ok) {
          log(`Restore execution request failed: ${data.error || res.status}`);
          alert(`Execute failed: ${data.error || res.status}`);
          return;
        }

        restoreIdInput.value = data.restore_id;
        jobBadge.textContent = 'Queued';
        jobBadge.className = 'badge badge-queued';
        log(`Restore task queued with restore_id: ${data.restore_id}. Starting auto-polling...`);

        startPolling(data.restore_id);
      } catch (err) {
        log(`Restore execution error: ${err.message}`);
      }
    }

    async function checkStatus(restoreId) {
      const id = restoreId || restoreIdInput.value.trim();
      if (!id) {
        alert('Please enter a Restore ID.');
        return;
      }

      try {
        const res = await fetch(`/cgi-bin/api/restore/status?id=${encodeURIComponent(id)}`, { headers: authHeaders() });
        const data = await res.json();

        if (!res.ok || !data.ok) {
          log(`Status check failed for ${id}: ${data.error || res.status}`);
          return;
        }

        jobBadge.textContent = data.status.toUpperCase();
        if (data.status === 'running') jobBadge.className = 'badge badge-running';
        else if (data.status === 'success') jobBadge.className = 'badge badge-success';
        else if (data.status === 'failed') jobBadge.className = 'badge badge-failed';
        else jobBadge.className = 'badge badge-queued';

        log(`Status [${data.status}]: ${data.message}${data.last_log ? ' | Last log: ' + data.last_log : ''}`);

        if (data.status === 'success' || data.status === 'failed') {
          if (pollInterval) {
            clearInterval(pollInterval);
            pollInterval = null;
          }
        }
      } catch (err) {
        log(`Status check error: ${err.message}`);
      }
    }

    function startPolling(id) {
      if (pollInterval) clearInterval(pollInterval);
      pollInterval = setInterval(() => checkStatus(id), 3000);
      checkStatus(id);
    }

    loadBackupsBtn.addEventListener('click', loadBackups);
    executeRestoreBtn.addEventListener('click', executeRestore);
    checkStatusBtn.addEventListener('click', () => checkStatus());

    loadSavedToken();
  </script>
</body>
</html>
EOF
}

function handle_ui() {
    send_html "200 OK" "$(dashboard_ui_html)"
}

function handle_api() {
    local PATH_INFO_VALUE

    PATH_INFO_VALUE="${PATH_INFO:-/}"

    case "${PATH_INFO_VALUE}" in
        /backups/recent)
            handle_recent_backups
            ;;
        /restore/dry-run)
            handle_restore_dry_run
            ;;
        /restore/execute)
            handle_restore_execute
            ;;
        /restore/status)
            handle_restore_status
            ;;
        *)
            send_not_found
            ;;
    esac
}

function handle_cgi() {
    local CGI_MODE="$1"

    INIT_ENV_LOG="FALSE"
    init_env

    mkdir -p "${DASHBOARD_STATE_DIR}"

    case "${CGI_MODE}" in
        ui)
            handle_ui
            ;;
        api)
            if ! require_admin_token; then
                send_unauthorized
                return
            fi
            handle_api
            ;;
        *)
            send_not_found
            ;;
    esac
}

function prepare_dashboard_webroot() {
    mkdir -p "${DASHBOARD_CGI_DIR}" "${DASHBOARD_STATE_DIR}"

    cat > "${DASHBOARD_CGI_DIR}/ui" <<'EOF'
#!/bin/bash
exec /app/dashboard.sh cgi ui
EOF

    cat > "${DASHBOARD_CGI_DIR}/api" <<'EOF'
#!/bin/bash
exec /app/dashboard.sh cgi api
EOF

    cat > "${DASHBOARD_WWW_DIR}/index.html" <<'EOF'
<!doctype html>
<html>
<head>
  <meta http-equiv="refresh" content="0; url=/cgi-bin/ui">
  <title>Redirecting...</title>
</head>
<body>
  <p>Redirecting to <a href="/cgi-bin/ui">Dashboard</a>...</p>
</body>
</html>
EOF

    chmod +x "${DASHBOARD_CGI_DIR}/ui" "${DASHBOARD_CGI_DIR}/api"
}

function start_dashboard() {
    init_env

    if [[ "${DASHBOARD_ENABLE}" != "TRUE" && "$1" != "--force" ]]; then
        color yellow "dashboard is disabled, skipping"
        return
    fi

    if [[ -z "${DASHBOARD_ADMIN_TOKEN}" ]]; then
        color red "dashboard requires ADMIN_TOKEN or VAULTWARDEN_ADMIN_TOKEN"
        exit 1
    fi

    prepare_dashboard_webroot

    color blue "starting dashboard at http://${DASHBOARD_BIND_ADDR}:${DASHBOARD_PORT}/cgi-bin/ui"

    # Create a Python CGI HTTP server launcher
    local CGI_SERVER_SCRIPT="${DASHBOARD_ROOT}/cgi_server.py"
    cat > "${CGI_SERVER_SCRIPT}" <<'PYEOF'
#!/usr/bin/env python3
import os, sys, re, io
from http.server import CGIHTTPRequestHandler, HTTPServer
from subprocess import Popen, PIPE

os.chdir(os.environ.get('WWW_ROOT', '/tmp'))
os.environ['PYTHONUNBUFFERED'] = '1'

class StatusAwareCGIHandler(CGIHTTPRequestHandler):
    cgi_directories = ['/cgi-bin']

    def do_GET(self):
        if self.path in ('', '/'):
            self.send_response(302)
            self.send_header('Location', '/cgi-bin/ui')
            self.end_headers()
            return
        super().do_GET()

    def run_cgi(self):
        """Override to properly handle CGI Status header"""
        # Parse path to find the CGI script
        path = self.path.split('?')[0]  # Remove query string

        # For /cgi-bin/api or /cgi-bin/api/backups/recent, we want to find /cgi-bin/api
        scriptname = None
        for cgi_dir in self.cgi_directories:
            if path.startswith(cgi_dir):
                # Find the actual script file by checking existence
                parts = path.split('/')
                for i in range(len(parts), 0, -1):
                    potential_script = '/'.join(parts[:i])
                    scriptfile = self.translate_path(potential_script)
                    if os.path.isfile(scriptfile):
                        scriptname = potential_script
                        break
                if scriptname:
                    break

        if not scriptname:
            self.send_error(404, "CGI script not found")
            return

        scriptfile = self.translate_path(scriptname)

        # Set up CGI environment
        env = os.environ.copy()
        env['SERVER_SOFTWARE'] = self.version_string()
        env['SERVER_NAME'] = self.server.server_name
        env['SERVER_PORT'] = str(self.server.server_port)
        env['REQUEST_METHOD'] = self.command
        env['SCRIPT_NAME'] = scriptname
        env['SCRIPT_FILENAME'] = scriptfile
        env['QUERY_STRING'] = self.path.split('?', 1)[1] if '?' in self.path else ''
        env['PATH_INFO'] = path[len(scriptname):]

        # Add HTTP headers to environment
        for header, value in self.headers.items():
            header_name = header.upper().replace('-', '_')
            if header_name in ('CONTENT_TYPE', 'CONTENT_LENGTH'):
                env[header_name] = value
            else:
                env['HTTP_' + header_name] = value

        env['REMOTE_ADDR'] = self.client_address[0]

        # Read request body for POST
        if self.command == 'POST':
            length = int(env.get('CONTENT_LENGTH', 0))
            stdin_data = self.rfile.read(length)
        else:
            stdin_data = b''

        # Run the CGI script
        try:
            proc = Popen(['/bin/bash', scriptfile],
                         stdin=PIPE,
                         stdout=PIPE, stderr=PIPE, env=env)
            output, error = proc.communicate(input=stdin_data)
        except Exception as e:
            self.send_error(500, f"Error executing CGI script: {e}")
            return

        # Parse CGI output
        output_str = output.decode('utf-8', errors='ignore')

        # Find header/body boundary
        header_end = output_str.find('\n\n')
        if header_end == -1:
            headers_text = output_str
            body = ''
        else:
            headers_text = output_str[:header_end]
            body = output_str[header_end+2:]

        # Parse headers and status
        status_code = 200
        response_headers = {}

        for line in headers_text.split('\n'):
            line = line.rstrip('\r')
            if not line:
                continue

            if line.startswith('Status:'):
                match = re.match(r'Status:\s+(\d+)', line)
                if match:
                    status_code = int(match.group(1))
            elif ':' in line:
                key, val = line.split(':', 1)
                response_headers[key.strip()] = val.strip()

        # Send response
        self.send_response(status_code)
        for key, val in response_headers.items():
            self.send_header(key, val)
        self.end_headers()

        if body:
            self.wfile.write(body.encode('utf-8'))

httpd = HTTPServer((os.environ.get('BIND_ADDR', '0.0.0.0'), int(os.environ.get('PORT', '8080'))), StatusAwareCGIHandler)
print(f"Server running at http://{os.environ.get('BIND_ADDR', '0.0.0.0')}:{os.environ.get('PORT', '8080')}/cgi-bin/ui", file=sys.stderr)
sys.stderr.flush()
httpd.serve_forever()
PYEOF

    chmod +x "${CGI_SERVER_SCRIPT}"

    export WWW_ROOT="${DASHBOARD_WWW_DIR}"
    export BIND_ADDR="${DASHBOARD_BIND_ADDR}"
    export PORT="${DASHBOARD_PORT}"

    exec python3 "${CGI_SERVER_SCRIPT}"
}

if [[ "$1" == "cgi" ]]; then
    shift
    handle_cgi "$1"
fi
