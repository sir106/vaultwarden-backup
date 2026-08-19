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

    if [[ "${PROVIDED_TOKEN}" != "${DASHBOARD_ADMIN_TOKEN}" ]]; then
        append_activity_log "auth_rejected" "invalid or missing token"
        return 1
    fi

    return 0
}

function is_supported_backup_file() {
    case "$1" in
        backup.*.zip|backup.*.7z|db.*.sqlite3|db.*.dump|db.*.sql|config.*.json|rsakey.*.tar|attachments.*.tar|sends.*.tar)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

function detect_restore_flag() {
    case "$1" in
        backup.*.zip|backup.*.7z) echo -n "--zip-file" ;;
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
            if [[ "${FIRST}" == "TRUE" ]]; then
                FIRST="FALSE"
            else
                RESULT+=" ,"
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

    printf '{"ok":true,"dry_run_id":"%s","remote":"%s","file":"%s","restore_flag":"%s"}' \
      "$(json_escape "${DRY_RUN_ID}")" \
      "$(json_escape "${REMOTE}")" \
      "$(json_escape "${FILE_NAME}")" \
      "$(json_escape "${RESTORE_FLAG}")" | while IFS= read -r JSON; do
        send_json "200 OK" "${JSON}"
      done
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
        echo "[dashboard] downloading ${file} from ${remote}"
        rclone ${RCLONE_GLOBAL_FLAG} copyto "${remote}/${file}" "${RESTORE_TARGET_FILE}"
        if [[ $? != 0 ]]; then
            echo "[dashboard] download failed"
            write_restore_status "${RESTORE_ID}" "failed" "download failed" "${file}" "${remote}"
            append_activity_log "restore_execute_failed" "id=${RESTORE_ID};reason=download_failed"
            return
        fi

        echo "[dashboard] running restore"
        . /app/restore.sh

        if [[ "${restore_flag}" == "--zip-file" && -n "${ZIP_PASSWORD_VALUE}" ]]; then
            restore -f -p "${ZIP_PASSWORD_VALUE}" "${restore_flag}" "${file}"
        else
            restore -f "${restore_flag}" "${file}"
        fi

        if [[ $? != 0 ]]; then
            echo "[dashboard] restore failed"
            write_restore_status "${RESTORE_ID}" "failed" "restore command failed" "${file}" "${remote}"
            append_activity_log "restore_execute_failed" "id=${RESTORE_ID};reason=restore_failed"
            return
        fi

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

    printf '{"ok":true,"restore_id":"%s","status":"queued"}' "$(json_escape "${RESTORE_ID}")" | while IFS= read -r JSON; do
        send_json "200 OK" "${JSON}"
    done
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
  <style>
    :root {
      --bg: #f8fafc;
      --panel: #ffffff;
      --ink: #0f172a;
      --muted: #475569;
      --accent: #0f766e;
      --accent2: #164e63;
      --danger: #b91c1c;
      --line: #cbd5e1;
    }
    body {
      margin: 0;
      font-family: "Trebuchet MS", "Segoe UI", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at 15% 10%, #dbeafe 0, transparent 32%),
        radial-gradient(circle at 82% 14%, #cffafe 0, transparent 28%),
        linear-gradient(160deg, #f8fafc, #eef2ff);
      min-height: 100vh;
    }
    .wrap {
      max-width: 980px;
      margin: 24px auto;
      padding: 16px;
    }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 16px;
      box-shadow: 0 6px 24px rgba(15, 23, 42, 0.08);
      margin-bottom: 16px;
    }
    h1 { margin: 0 0 8px; letter-spacing: 0.2px; }
    .muted { color: var(--muted); }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 14px;
    }
    th, td {
      border-bottom: 1px solid var(--line);
      text-align: left;
      padding: 10px 8px;
      vertical-align: middle;
    }
    button {
      border: none;
      border-radius: 10px;
      padding: 8px 12px;
      font-weight: 600;
      cursor: pointer;
      color: #fff;
      background: linear-gradient(120deg, var(--accent), var(--accent2));
    }
    button.danger { background: var(--danger); }
    .row { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
    input[type="password"], input[type="text"] {
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 8px;
      min-width: 220px;
    }
    .status {
      padding: 10px;
      border-left: 4px solid var(--accent);
      background: #f1f5f9;
      white-space: pre-wrap;
      word-break: break-word;
    }
    @media (max-width: 760px) {
      table, thead, tbody, th, td, tr { display: block; }
      th { display: none; }
      tr { border: 1px solid var(--line); margin-bottom: 10px; border-radius: 10px; }
      td { border: none; border-bottom: 1px solid var(--line); }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="panel">
      <h1>Vaultwarden Backup Dashboard</h1>
      <div class="muted">Review recent remote backups, run dry-run validation, and start restore jobs.</div>
      <div class="row" style="margin-top:10px;">
        <input id="token" type="password" placeholder="ADMIN_TOKEN" />
        <button id="load">Load Recent Backups</button>
      </div>
    </div>

    <div class="panel">
      <table>
        <thead><tr><th>Remote</th><th>File</th><th>Size</th><th>Modified</th><th>Action</th></tr></thead>
        <tbody id="rows"></tbody>
      </table>
    </div>

    <div class="panel">
      <div class="row">
        <input id="dryRunId" type="text" placeholder="Dry run id" />
        <input id="zipPassword" type="password" placeholder="Zip password (if needed)" />
        <button id="execute" class="danger">Execute Restore</button>
      </div>
      <div class="row" style="margin-top:8px;">
        <input id="restoreId" type="text" placeholder="Restore id" />
        <button id="status">Check Status</button>
      </div>
      <div id="statusText" class="status" style="margin-top:10px;">Status will appear here.</div>
    </div>
  </div>

<script>
const rowsEl = document.getElementById('rows');
const tokenEl = document.getElementById('token');
const dryRunIdEl = document.getElementById('dryRunId');
const zipPasswordEl = document.getElementById('zipPassword');
const restoreIdEl = document.getElementById('restoreId');
const statusText = document.getElementById('statusText');

function authHeaders() {
  return { 'X-Admin-Token': tokenEl.value };
}

function setStatus(text) {
  statusText.textContent = text;
}

async function fetchRecent() {
  rowsEl.innerHTML = '';
  setStatus('Loading recent backups...');

  const res = await fetch('/cgi-bin/api/backups/recent?limit=40', { headers: authHeaders() });
  const data = await res.json();

  if (!res.ok || !data.ok) {
    setStatus('Failed to load backups: ' + (data.error || res.status));
    return;
  }

  for (const item of data.items) {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>${item.remote}</td>
      <td>${item.file}</td>
      <td>${item.size}</td>
      <td>${item.modified}</td>
      <td><button data-remote="${item.remote}" data-file="${item.file}">Dry Run</button></td>
    `;

    tr.querySelector('button').addEventListener('click', () => dryRun(item.remote, item.file));
    rowsEl.appendChild(tr);
  }

  setStatus('Loaded ' + data.items.length + ' backup entries.');
}

async function dryRun(remote, file) {
  setStatus('Running dry-run for ' + file + '...');

  const body = new URLSearchParams({ remote, file }).toString();
  const res = await fetch('/cgi-bin/api/restore/dry-run', {
    method: 'POST',
    headers: { ...authHeaders(), 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  const data = await res.json();

  if (!res.ok || !data.ok) {
    setStatus('Dry-run failed: ' + (data.error || res.status));
    return;
  }

  dryRunIdEl.value = data.dry_run_id;
  setStatus('Dry-run success. dry_run_id=' + data.dry_run_id + ' restore_flag=' + data.restore_flag);
}

async function executeRestore() {
  const dry_run_id = dryRunIdEl.value.trim();
  const password = zipPasswordEl.value;

  if (!dry_run_id) {
    setStatus('dry_run_id is required.');
    return;
  }

  setStatus('Submitting restore job...');

  const body = new URLSearchParams({ dry_run_id, password, force: 'true' }).toString();
  const res = await fetch('/cgi-bin/api/restore/execute', {
    method: 'POST',
    headers: { ...authHeaders(), 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  const data = await res.json();

  if (!res.ok || !data.ok) {
    setStatus('Execute failed: ' + (data.error || res.status));
    return;
  }

  restoreIdEl.value = data.restore_id;
  setStatus('Restore queued. restore_id=' + data.restore_id);
}

async function checkStatus() {
  const id = restoreIdEl.value.trim();
  if (!id) {
    setStatus('restore_id is required.');
    return;
  }

  const res = await fetch('/cgi-bin/api/restore/status?id=' + encodeURIComponent(id), { headers: authHeaders() });
  const data = await res.json();

  if (!res.ok || !data.ok) {
    setStatus('Status request failed: ' + (data.error || res.status));
    return;
  }

  setStatus(JSON.stringify(data, null, 2));
}

document.getElementById('load').addEventListener('click', fetchRecent);
document.getElementById('execute').addEventListener('click', executeRestore);
document.getElementById('status').addEventListener('click', checkStatus);
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

    if ! require_admin_token; then
        send_unauthorized
        return
    fi

    mkdir -p "${DASHBOARD_STATE_DIR}"

    case "${CGI_MODE}" in
        ui)
            handle_ui
            ;;
        api)
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
