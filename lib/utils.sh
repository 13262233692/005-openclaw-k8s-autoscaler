#!/bin/bash

# Open Claw - Utility Layer
# Logging, common utilities, and helper functions
#
# NOTE: This module has been refactored to eliminate pipeline deadlocks.
# Key changes:
#   - Temporary file buffer mechanism instead of echo | pipe for large data
#   - Timeout enforcement for all subprocess calls
#   - Strict exit code checking and zombie process reaping
#   - Safe JSON parsing via temp files, avoiding stdin pipe deadlocks

OPENCLAW_UTILS_LOADED=1

OPENCLAW_LOG_COLORS=true
if [[ ! -t 1 ]]; then
    OPENCLAW_LOG_COLORS=false
fi

OPENCLAW_TMPDIR=""
OPENCLAW_TMPFILES=()
OPENCLAW_DEFAULT_TIMEOUT="${OPENCLAW_DEFAULT_TIMEOUT:-120}"

openclaw_log_color_reset="\033[0m"
openclaw_log_color_red="\033[31m"
openclaw_log_color_green="\033[32m"
openclaw_log_color_yellow="\033[33m"
openclaw_log_color_blue="\033[34m"
openclaw_log_color_magenta="\033[35m"
openclaw_log_color_cyan="\033[36m"
openclaw_log_color_gray="\033[90m"

openclaw_log_level_value() {
    case "$1" in
        DEBUG) echo 0 ;;
        INFO) echo 1 ;;
        WARN) echo 2 ;;
        ERROR) echo 3 ;;
        *) echo 1 ;;
    esac
}

openclaw_should_log() {
    local msg_level="$1"
    local current_level="${OPENCLAW_LOG_LEVEL:-INFO}"
    local msg_val=$(openclaw_log_level_value "$msg_level")
    local cur_val=$(openclaw_log_level_value "$current_level")
    [[ $msg_val -ge $cur_val ]]
}

openclaw_log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if ! openclaw_should_log "$level"; then
        return 0
    fi

    local color=""
    local level_label=""

    case "$level" in
        DEBUG)
            color="$openclaw_log_color_gray"
            level_label="DEBUG"
            ;;
        INFO)
            color="$openclaw_log_color_blue"
            level_label="INFO "
            ;;
        WARN)
            color="$openclaw_log_color_yellow"
            level_label="WARN "
            ;;
        ERROR)
            color="$openclaw_log_color_red"
            level_label="ERROR"
            ;;
        SUCCESS)
            color="$openclaw_log_color_green"
            level_label=" OK  "
            ;;
        *)
            color=""
            level_label="     "
            ;;
    esac

    if [[ "$OPENCLAW_LOG_COLORS" == "true" ]]; then
        echo -e "${color}[${timestamp}] [${level_label}] ${msg}${openclaw_log_color_reset}"
    else
        echo "[${timestamp}] [${level_label}] ${msg}"
    fi
}

openclaw_log_debug() {
    openclaw_log "DEBUG" "$@"
}

openclaw_log_info() {
    openclaw_log "INFO" "$@"
}

openclaw_log_warn() {
    openclaw_log "WARN" "$@"
}

openclaw_log_error() {
    openclaw_log "ERROR" "$@" >&2
}

openclaw_log_success() {
    openclaw_log "SUCCESS" "$@"
}

openclaw_generate_id() {
    local length="${1:-8}"
    local id=""
    if command -v openssl &>/dev/null; then
        id=$(openssl rand -hex "$((length / 2))" 2>/dev/null || head -c "$length" /dev/urandom | od -An -tx1 | tr -d ' \n')
    else
        id=$(date +%s%N | sha256sum | head -c "$length")
    fi
    echo "$id"
}

openclaw_generate_trace_id() {
    local ts
    ts=$(date +%s)
    local rand
    rand=$(openclaw_generate_id 6)
    echo "${ts}-${rand}"
}

openclaw_json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "$str"
}

openclaw_is_dry_run() {
    [[ "${OPENCLAW_DRY_RUN:-false}" == "true" ]]
}

openclaw_check_dependency() {
    local cmd="$1"
    local name="${2:-$cmd}"
    if ! command -v "$cmd" &>/dev/null; then
        openclaw_log_error "Required dependency '${name}' not found: ${cmd}"
        return 1
    fi
    return 0
}

openclaw_validate_name() {
    local name="$1"
    local pattern='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
    if [[ "$name" =~ $pattern ]]; then
        return 0
    fi
    return 1
}

openclaw_validate_percent() {
    local value="$1"
    if [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -ge 0 ]] && [[ "$value" -le 100 ]]; then
        return 0
    fi
    return 1
}

openclaw_validate_positive_int() {
    local value="$1"
    if [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -gt 0 ]]; then
        return 0
    fi
    return 1
}

openclaw_format_duration() {
    local seconds="$1"
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}s"
    elif [[ $seconds -lt 3600 ]]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m${secs}s"
    else
        local hours=$((seconds / 3600))
        local mins=$(( (seconds % 3600) / 60 ))
        echo "${hours}h${mins}m"
    fi
}

openclaw_confirm_action() {
    local message="$1"
    local default="${2:-n}"

    if [[ "${OPENCLAW_AUTO_YES:-false}" == "true" ]]; then
        return 0
    fi

    local prompt
    if [[ "$default" == "y" ]]; then
        prompt="${message} [Y/n] "
    else
        prompt="${message} [y/N] "
    fi

    read -r -p "$prompt" answer
    answer="${answer:-$default}"

    case "$answer" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

openclaw_array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

openclaw_get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

openclaw_get_timestamp_ms() {
    if date +%s%3N &>/dev/null; then
        date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
    else
        date -u +"%Y-%m-%dT%H:%M:%SZ"
    fi
}

# ============================================================
# Temporary File Buffer Management
# Eliminates pipeline deadlocks by using temp files instead of
# echo | pipe for large data transfers between processes.
# ============================================================

openclaw_tmpdir_init() {
    if [[ -n "$OPENCLAW_TMPDIR" && -d "$OPENCLAW_TMPDIR" ]]; then
        return 0
    fi

    local prefix="openclaw-${$}-$(openclaw_generate_id 6)"
    local base_tmp="${TMPDIR:-/tmp}"

    if [[ ! -d "$base_tmp" ]]; then
        base_tmp="${OPENCLAW_ROOT}/.tmp"
    fi

    OPENCLAW_TMPDIR="${base_tmp}/${prefix}"

    if ! mkdir -p "$OPENCLAW_TMPDIR" 2>/dev/null; then
        openclaw_log_error "Failed to create temp directory: ${OPENCLAW_TMPDIR}"
        return 1
    fi

    chmod 700 "$OPENCLAW_TMPDIR" 2>/dev/null || true

    openclaw_log_debug "Temp directory initialized: ${OPENCLAW_TMPDIR}"
    return 0
}

openclaw_tmpfile_create() {
    local suffix="${1:-tmp}"

    if [[ -z "$OPENCLAW_TMPDIR" ]]; then
        openclaw_tmpdir_init || return 1
    fi

    local filename="tmp-$(openclaw_generate_id 10).${suffix}"
    local filepath="${OPENCLAW_TMPDIR}/${filename}"

    : > "$filepath" 2>/dev/null || {
        openclaw_log_error "Failed to create temp file: ${filepath}"
        return 1
    }

    OPENCLAW_TMPFILES+=("$filepath")
    echo "$filepath"
    return 0
}

openclaw_tmpfile_cleanup() {
    if [[ -n "$OPENCLAW_TMPDIR" && -d "$OPENCLAW_TMPDIR" ]]; then
        openclaw_log_debug "Cleaning up temp directory: ${OPENCLAW_TMPDIR}"
        rm -rf "$OPENCLAW_TMPDIR" 2>/dev/null || true
    fi
    OPENCLAW_TMPDIR=""
    OPENCLAW_TMPFILES=()
}

trap 'openclaw_tmpfile_cleanup' EXIT INT TERM HUP

# ============================================================
# Safe Subprocess Execution with Timeout
# Prevents defunct (zombie) processes and pipeline hangs.
# Uses temp file capture instead of variable capture for large output.
# ============================================================

openclaw_exec_with_timeout() {
    local timeout_sec="${1:-$OPENCLAW_DEFAULT_TIMEOUT}"
    shift
    local cmd_parts=("$@")

    if ! openclaw_validate_positive_int "$timeout_sec"; then
        openclaw_log_error "Invalid timeout value: ${timeout_sec}"
        return 1
    fi

    local stdout_file
    local stderr_file
    stdout_file=$(openclaw_tmpfile_create "stdout") || return 1
    stderr_file=$(openclaw_tmpfile_create "stderr") || return 1

    local cmd_pid
    local timeout_pid
    local exit_code=0

    openclaw_log_debug "Executing with ${timeout_sec}s timeout: ${cmd_parts[*]}"

    (
        "${cmd_parts[@]}" >"$stdout_file" 2>"$stderr_file"
        echo $? > "${stdout_file}.exit"
    ) &
    cmd_pid=$!

    (
        local remaining="$timeout_sec"
        while [[ $remaining -gt 0 ]]; do
            if ! kill -0 "$cmd_pid" 2>/dev/null; then
                exit 0
            fi
            sleep 1
            remaining=$((remaining - 1))
        done
        if kill -0 "$cmd_pid" 2>/dev/null; then
            openclaw_log_warn "Command timed out after ${timeout_sec}s, sending SIGTERM to PID ${cmd_pid}"
            kill -TERM "$cmd_pid" 2>/dev/null || true
            sleep 2
            if kill -0 "$cmd_pid" 2>/dev/null; then
                openclaw_log_error "Command still alive after SIGTERM, sending SIGKILL to PID ${cmd_pid}"
                kill -KILL "$cmd_pid" 2>/dev/null || true
            fi
            echo "124" > "${stdout_file}.exit"
        fi
    ) &
    timeout_pid=$!

    wait "$cmd_pid" 2>/dev/null
    local wait_exit=$?

    if kill -0 "$timeout_pid" 2>/dev/null; then
        kill -TERM "$timeout_pid" 2>/dev/null || true
        wait "$timeout_pid" 2>/dev/null || true
    fi

    if [[ -f "${stdout_file}.exit" ]]; then
        exit_code=$(cat "${stdout_file}.exit" 2>/dev/null || echo "1")
    else
        exit_code=$wait_exit
    fi

    OPENCLAW_LAST_STDOUT_FILE="$stdout_file"
    OPENCLAW_LAST_STDERR_FILE="$stderr_file"
    OPENCLAW_LAST_EXIT_CODE="$exit_code"

    if [[ $exit_code -eq 124 ]]; then
        openclaw_log_error "Command timed out after ${timeout_sec}s: ${cmd_parts[*]}"
    fi

    return $exit_code
}

openclaw_read_stdout_file() {
    if [[ -n "${OPENCLAW_LAST_STDOUT_FILE:-}" && -f "${OPENCLAW_LAST_STDOUT_FILE}" ]]; then
        cat "${OPENCLAW_LAST_STDOUT_FILE}"
    fi
}

openclaw_read_stderr_file() {
    if [[ -n "${OPENCLAW_LAST_STDERR_FILE:-}" && -f "${OPENCLAW_LAST_STDERR_FILE}" ]]; then
        cat "${OPENCLAW_LAST_STDERR_FILE}"
    fi
}

# ============================================================
# Safe JSON Processing
# Replaces echo "$json" | python3/jq patterns which cause
# pipeline buffer deadlocks with large/abnormal JSON data.
# Uses temp files to decouple writer and reader processes.
# ============================================================

openclaw_is_valid_json() {
    local input="$1"

    local json_file
    json_file=$(openclaw_tmpfile_create "json") || return 1

    printf '%s' "$input" > "$json_file" 2>/dev/null

    if command -v python3 &>/dev/null; then
        openclaw_exec_with_timeout 30 python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'r') as f:
        json.load(f)
    sys.exit(0)
except Exception:
    sys.exit(1)
" "$json_file" 2>/dev/null
        return $?
    elif command -v jq &>/dev/null; then
        openclaw_exec_with_timeout 30 jq empty "$json_file" 2>/dev/null
        return $?
    else
        openclaw_log_warn "No JSON parser available, skipping validation"
        return 0
    fi
}

openclaw_is_valid_json_file() {
    local json_file="$1"

    if [[ ! -f "$json_file" ]]; then
        openclaw_log_debug "JSON file not found: ${json_file}"
        return 1
    fi

    if command -v python3 &>/dev/null; then
        openclaw_exec_with_timeout 60 python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'r') as f:
        json.load(f)
    sys.exit(0)
except Exception as e:
    sys.stderr.write(str(e) + '\n')
    sys.exit(1)
" "$json_file"
        return $?
    elif command -v jq &>/dev/null; then
        openclaw_exec_with_timeout 60 jq empty "$json_file" 2>/dev/null
        return $?
    else
        openclaw_log_warn "No JSON parser available, skipping validation"
        return 0
    fi
}

openclaw_extract_json_field() {
    local json="$1"
    local field="$2"

    local json_file
    json_file=$(openclaw_tmpfile_create "json") || return 1

    printf '%s' "$json" > "$json_file" 2>/dev/null

    openclaw_extract_json_field_file "$json_file" "$field"
}

openclaw_extract_json_field_file() {
    local json_file="$1"
    local field="$2"

    if [[ ! -f "$json_file" ]]; then
        echo "null"
        return 1
    fi

    local output_file
    output_file=$(openclaw_tmpfile_create "jsonout") || { echo "null"; return 1; }

    if command -v jq &>/dev/null; then
        if openclaw_exec_with_timeout 60 jq -r "$field" "$json_file" >/dev/null 2>&1; then
            jq -r "$field" "$json_file" 2>/dev/null > "$output_file" || true
        else
            echo "null" > "$output_file"
        fi
    elif command -v python3 &>/dev/null; then
        openclaw_exec_with_timeout 60 python3 -c "
import json, sys

json_path = sys.argv[1]
field_path = sys.argv[2]
output_path = sys.argv[3]

try:
    with open(json_path, 'r') as f:
        data = json.load(f)

    keys = field_path.lstrip('.').split('.')
    val = data
    for k in keys:
        if isinstance(val, dict) and k in val:
            val = val[k]
        else:
            val = None
            break

    with open(output_path, 'w') as f:
        if val is None:
            f.write('null')
        elif isinstance(val, (dict, list)):
            f.write(json.dumps(val))
        else:
            f.write(str(val))
    sys.exit(0)
except Exception as e:
    with open(output_path, 'w') as f:
        f.write('null')
    sys.exit(1)
" "$json_file" "$field" "$output_file" 2>/dev/null || true
    else
        openclaw_log_error "No JSON parser available (jq or python3 required)"
        echo "null" > "$output_file"
    fi

    cat "$output_file" 2>/dev/null || echo "null"
}

openclaw_process_json_script_file() {
    local json_file="$1"
    local python_script="$2"
    local timeout_sec="${3:-60}"

    if [[ ! -f "$json_file" ]]; then
        openclaw_log_error "JSON input file not found: ${json_file}"
        return 1
    fi

    local script_file
    script_file=$(openclaw_tmpfile_create "py") || return 1
    local output_file
    output_file=$(openclaw_tmpfile_create "out") || return 1

    printf '%s' "$python_script" > "$script_file"

    if openclaw_exec_with_timeout "$timeout_sec" python3 "$script_file" "$json_file" "$output_file"; then
        cat "$output_file" 2>/dev/null
        return 0
    else
        local err_output
        err_output=$(openclaw_read_stderr_file)
        if [[ -n "$err_output" ]]; then
            openclaw_log_debug "Python script stderr: ${err_output}"
        fi
        cat "$output_file" 2>/dev/null || true
        return 1
    fi
}

openclaw_reap_zombies() {
    if command -v kill &>/dev/null; then
        if [[ -n "${OPENCLAW_CHILD_PIDS:-}" ]]; then
            local pid
            for pid in ${OPENCLAW_CHILD_PIDS}; do
                if kill -0 "$pid" 2>/dev/null; then
                    kill -TERM "$pid" 2>/dev/null || true
                fi
            done
        fi
    fi

    wait 2>/dev/null || true
}

trap 'openclaw_reap_zombies; openclaw_tmpfile_cleanup' EXIT INT TERM HUP
