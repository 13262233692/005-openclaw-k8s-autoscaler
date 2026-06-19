#!/bin/bash

# Open Claw - Utility Layer
# Logging, common utilities, and helper functions

OPENCLAW_UTILS_LOADED=1

OPENCLAW_LOG_COLORS=true
if [[ ! -t 1 ]]; then
    OPENCLAW_LOG_COLORS=false
fi

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

openclaw_is_valid_json() {
    local input="$1"
    if command -v python3 &>/dev/null; then
        echo "$input" | python3 -c "import json,sys; json.load(sys.stdin)" &>/dev/null
        return $?
    elif command -v jq &>/dev/null; then
        echo "$input" | jq empty &>/dev/null
        return $?
    else
        openclaw_log_warn "No JSON parser available, skipping validation"
        return 0
    fi
}

openclaw_extract_json_field() {
    local json="$1"
    local field="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r "$field" 2>/dev/null
    elif command -v python3 &>/dev/null; then
        echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
keys = '$field'.lstrip('.').split('.')
val = data
for k in keys:
    if isinstance(val, dict) and k in val:
        val = val[k]
    else:
        print('null')
        sys.exit(0)
if isinstance(val, (dict, list)):
    print(json.dumps(val))
else:
    print(val)
" 2>/dev/null
    else
        openclaw_log_error "No JSON parser available (jq or python3 required)"
        return 1
    fi
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
