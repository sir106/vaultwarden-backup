#!/bin/bash

# Unit test for GFS retention policy logic

TEST_NAME="backup-retention-gfs"
FAILED_NUM=0

function color() {
    case $1 in
        red)     echo -e "\033[31m$2\033[0m" ;;
        green)   echo -e "\033[32m$2\033[0m" ;;
        yellow)  echo -e "\033[33m$2\033[0m" ;;
        blue)    echo -e "\033[34m$2\033[0m" ;;
        none)    echo "$2" ;;
    esac
}

# Standalone implementation of GFS evaluation for testing
function evaluate_retention() {
    local -n _remote_files=$1
    local keep_days=$2
    local keep_weeks=$3
    local keep_months=$4
    local keep_years=$5
    local keep_last=$6
    local -n _out_kept=$7
    local -n _out_deleted=$8

    _out_kept=()
    _out_deleted=()

    if [[ "${keep_days}" -eq 0 && "${keep_weeks}" -eq 0 && "${keep_months}" -eq 0 && "${keep_years}" -eq 0 && "${keep_last}" -eq 0 ]]; then
        return 0
    fi

    declare -A SNAPSHOT_TIMESTAMP=()
    declare -A SNAPSHOT_FILES=()
    local SNAPSHOT_IDS=()

    for FILE_ENTRY in "${_remote_files[@]}"; do
        [[ -z "${FILE_ENTRY}" ]] && continue

        local FILE_TS="${FILE_ENTRY%%;*}"
        local FILE_NAME="${FILE_ENTRY#*;}"
        local SNAP_ID=""

        if [[ "${FILE_NAME}" =~ ^backup\.(.+)\.(zip|7z)$ ]]; then
            SNAP_ID="pkg_${BASH_REMATCH[1]}"
        elif [[ "${FILE_NAME}" =~ ^(db|config|rsakey|attachments|sends)\.(.+)\.(sqlite3|dump|sql|json|tar)$ ]]; then
            SNAP_ID="unpacked_${BASH_REMATCH[2]}"
        else
            continue
        fi

        if [[ -z "${SNAPSHOT_TIMESTAMP[${SNAP_ID}]:-}" ]]; then
            SNAPSHOT_TIMESTAMP["${SNAP_ID}"]="${FILE_TS}"
            SNAPSHOT_FILES["${SNAP_ID}"]="${FILE_NAME}"
            SNAPSHOT_IDS+=("${SNAP_ID}")
        else
            SNAPSHOT_FILES["${SNAP_ID}"]="${SNAPSHOT_FILES[${SNAP_ID}]} ${FILE_NAME}"
        fi
    done

    local SORTED_SNAPSHOTS=()
    mapfile -t SORTED_SNAPSHOTS < <(
        for SNAP_ID in "${SNAPSHOT_IDS[@]}"; do
            echo "${SNAPSHOT_TIMESTAMP[${SNAP_ID}]};${SNAP_ID}"
        done | sort -r
    )

    declare -A KEPT_SNAPSHOTS=()
    declare -A SEEN_DAYS=()
    declare -A SEEN_WEEKS=()
    declare -A SEEN_MONTHS=()
    declare -A SEEN_YEARS=()
    local LAST_COUNT=0

    for SNAP_LINE in "${SORTED_SNAPSHOTS[@]}"; do
        [[ -z "${SNAP_LINE}" ]] && continue

        local SNAP_TS="${SNAP_LINE%%;*}"
        local SNAP_ID="${SNAP_LINE#*;}"
        local KEEP_THIS="FALSE"

        if [[ "${keep_last}" -gt 0 && "${LAST_COUNT}" -lt "${keep_last}" ]]; then
            KEEP_THIS="TRUE"
            ((LAST_COUNT++))
        fi

        local DAY_KEY="${SNAP_TS:0:10}"
        local MONTH_KEY="${SNAP_TS:0:7}"
        local YEAR_KEY="${SNAP_TS:0:4}"
        local WEEK_KEY
        WEEK_KEY=$(date -d "${SNAP_TS}" +"%G-W%V" 2>/dev/null)
        if [[ -z "${WEEK_KEY}" ]]; then
            WEEK_KEY="${DAY_KEY}"
        fi

        if [[ "${keep_days}" -gt 0 ]]; then
            if [[ -z "${SEEN_DAYS[${DAY_KEY}]:-}" && "${#SEEN_DAYS[@]}" -lt "${keep_days}" ]]; then
                SEEN_DAYS["${DAY_KEY}"]="1"
                KEEP_THIS="TRUE"
            fi
        fi

        if [[ "${keep_weeks}" -gt 0 ]]; then
            if [[ -z "${SEEN_WEEKS[${WEEK_KEY}]:-}" && "${#SEEN_WEEKS[@]}" -lt "${keep_weeks}" ]]; then
                SEEN_WEEKS["${WEEK_KEY}"]="1"
                KEEP_THIS="TRUE"
            fi
        fi

        if [[ "${keep_months}" -gt 0 ]]; then
            if [[ -z "${SEEN_MONTHS[${MONTH_KEY}]:-}" && "${#SEEN_MONTHS[@]}" -lt "${keep_months}" ]]; then
                SEEN_MONTHS["${MONTH_KEY}"]="1"
                KEEP_THIS="TRUE"
            fi
        fi

        if [[ "${keep_years}" -gt 0 ]]; then
            if [[ -z "${SEEN_YEARS[${YEAR_KEY}]:-}" && "${#SEEN_YEARS[@]}" -lt "${keep_years}" ]]; then
                SEEN_YEARS["${YEAR_KEY}"]="1"
                KEEP_THIS="TRUE"
            fi
        fi

        if [[ "${KEEP_THIS}" == "TRUE" ]]; then
            KEPT_SNAPSHOTS["${SNAP_ID}"]="1"
            _out_kept+=("${SNAP_ID}")
        fi
    done

    for SNAP_ID in "${SNAPSHOT_IDS[@]}"; do
        if [[ -z "${KEPT_SNAPSHOTS[${SNAP_ID}]:-}" ]]; then
            for DEL_FILE in ${SNAPSHOT_FILES[${SNAP_ID}]}; do
                _out_deleted+=("${DEL_FILE}")
            done
        fi
    done
}

# Test 1: Disabled retention (all 0)
FILES_TEST1=(
    "2026-08-16T08:00:00Z;backup.20260816.zip"
    "2026-08-15T08:00:00Z;backup.20260815.zip"
)
evaluate_retention FILES_TEST1 0 0 0 0 0 KEPT DELETED
if [[ "${#DELETED[@]}" -ne 0 ]]; then
    color red "Test 1 failed: Expected 0 deleted when retention disabled, got ${#DELETED[@]}"
    ((FAILED_NUM++))
else
    color green "Test 1 (disabled retention) passed"
fi

# Test 2: Daily retention (7 days), older files deleted
FILES_TEST2=()
for i in {0..10}; do
    d=$(date -d "2026-08-16 - $i days" +"%Y-%m-%d")
    tag=$(date -d "2026-08-16 - $i days" +"%Y%m%d")
    FILES_TEST2+=("${d}T08:00:00Z;backup.${tag}.zip")
done
evaluate_retention FILES_TEST2 7 0 0 0 0 KEPT DELETED
if [[ "${#KEPT[@]}" -ne 7 || "${#DELETED[@]}" -ne 4 ]]; then
    color red "Test 2 failed: Expected 7 kept and 4 deleted, got kept=${#KEPT[@]}, deleted=${#DELETED[@]}"
    ((FAILED_NUM++))
else
    color green "Test 2 (daily retention) passed"
fi

# Test 3: GFS defaults (7 days, 4 weeks, 12 months, 3 years) with history spanning 4 years
FILES_TEST3=()
# Generate 4 years of daily backups
for i in {0..1400}; do
    d=$(date -d "2026-08-16 - $i days" +"%Y-%m-%d")
    tag=$(date -d "2026-08-16 - $i days" +"%Y%m%d")
    FILES_TEST3+=("${d}T08:00:00Z;backup.${tag}.zip")
done
evaluate_retention FILES_TEST3 7 4 12 3 0 KEPT DELETED
color blue "Test 3: From 1401 backups, kept=${#KEPT[@]}, deleted=${#DELETED[@]}"
if [[ "${#KEPT[@]}" -lt 15 || "${#KEPT[@]}" -gt 30 || "${#DELETED[@]}" -lt 1370 ]]; then
    color red "Test 3 failed: Unexpected retention count kept=${#KEPT[@]}, deleted=${#DELETED[@]}"
    ((FAILED_NUM++))
else
    color green "Test 3 (GFS full retention) passed"
fi

# Test 4: Unpacked backups (multiple files per snapshot)
FILES_TEST4=(
    "2026-08-16T08:00:00Z;db.20260816.sqlite3"
    "2026-08-16T08:00:00Z;config.20260816.json"
    "2026-08-16T08:00:00Z;rsakey.20260816.tar"
    "2026-08-01T08:00:00Z;db.20260801.sqlite3"
    "2026-08-01T08:00:00Z;config.20260801.json"
    "2026-08-01T08:00:00Z;rsakey.20260801.tar"
    "2026-08-16T08:00:00Z;other_file.txt"
)
evaluate_retention FILES_TEST4 1 0 0 0 0 KEPT DELETED
if [[ "${#KEPT[@]}" -ne 1 || "${#DELETED[@]}" -ne 3 ]]; then
    color red "Test 4 failed: Expected 1 kept snapshot and 3 deleted files, got kept=${#KEPT[@]}, deleted=${#DELETED[@]}"
    ((FAILED_NUM++))
else
    color green "Test 4 (unpacked multi-file snapshots & non-backup file ignore) passed"
fi

if declare -f test_result > /dev/null; then
    test_result "${TEST_NAME}" "${FAILED_NUM}"
else
    if [[ "${FAILED_NUM}" -eq 0 ]]; then
        color green "All GFS retention unit tests passed"
        exit 0
    else
        color red "${FAILED_NUM} tests failed"
        exit 1
    fi
fi
