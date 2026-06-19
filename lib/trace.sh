#!/bin/bash

# Open Claw - Trace & Record Module (Model Recording Layer)
# Execution trace tracking and structured model output to local directory

OPENCLAW_TRACE_LOADED=1

OPENCLAW_TRACE_ID=""
OPENCLAW_TRACE_START_TIME=""
OPENCLAW_TRACE_END_TIME=""
OPENCLAW_TRACE_COMMAND=""
OPENCLAW_TRACE_ARGS=()
OPENCLAW_TRACE_STATUS="pending"
OPENCLAW_TRACE_EXIT_CODE=0

declare -A OPENCLAW_TRACE_CONTEXT
declare -A OPENCLAW_TRACE_RESULTS

OPENCLAW_TRACE_STEPS=()
declare -A OPENCLAW_TRACE_STEP_STATUS
declare -A OPENCLAW_TRACE_STEP_DETAIL
declare -A OPENCLAW_TRACE_STEP_START
declare -A OPENCLAW_TRACE_STEP_END

OPENCLAW_TRACE_EVENTS=()

OPENCLAW_TRACE_RECORD_DIR=""
OPENCLAW_TRACE_RECORD_FILE=""

openclaw_trace_start() {
    local command="$1"
    shift
    local args=("$@")

    OPENCLAW_TRACE_ID=$(openclaw_generate_trace_id)
    OPENCLAW_TRACE_START_TIME=$(openclaw_get_timestamp_ms)
    OPENCLAW_TRACE_COMMAND="$command"
    OPENCLAW_TRACE_ARGS=("$@")
    OPENCLAW_TRACE_STATUS="running"

    export OPENCLAW_TRACE_ID

    openclaw_trace_init_record_dir

    openclaw_log_debug "Trace started: ${OPENCLAW_TRACE_ID} (command: ${command})"

    openclaw_trace_set_context "command" "$command"
    openclaw_trace_set_context "namespace" "$OPENCLAW_KUBECTL_NAMESPACE"
    openclaw_trace_set_context "operator" "${USER:-unknown}"
    openclaw_trace_set_context "host" "${HOSTNAME:-unknown}"
    openclaw_trace_set_context "version" "$OPENCLAW_VERSION"
    openclaw_trace_set_context "dry_run" "${OPENCLAW_DRY_RUN:-false}"
}

openclaw_trace_init_record_dir() {
    local date_dir
    date_dir=$(date -u +"%Y-%m-%d")
    OPENCLAW_TRACE_RECORD_DIR="${OPENCLAW_RECORDS_DIR}/${date_dir}"

    if [[ ! -d "$OPENCLAW_TRACE_RECORD_DIR" ]]; then
        mkdir -p "$OPENCLAW_TRACE_RECORD_DIR" 2>/dev/null || true
    fi

    OPENCLAW_TRACE_RECORD_FILE="${OPENCLAW_TRACE_RECORD_DIR}/trace_${OPENCLAW_TRACE_ID}.json"

    openclaw_log_debug "Trace record file: ${OPENCLAW_TRACE_RECORD_FILE}"
}

openclaw_trace_end() {
    local exit_code="${1:-0}"

    OPENCLAW_TRACE_END_TIME=$(openclaw_get_timestamp_ms)
    OPENCLAW_TRACE_EXIT_CODE=$exit_code

    if [[ $exit_code -eq 0 ]]; then
        OPENCLAW_TRACE_STATUS="success"
    else
        OPENCLAW_TRACE_STATUS="failed"
    fi

    openclaw_log_debug "Trace ended: ${OPENCLAW_TRACE_ID} (status: ${OPENCLAW_TRACE_STATUS}, exit: ${exit_code})"

    openclaw_trace_save

    return $exit_code
}

openclaw_trace_set_context() {
    local key="$1"
    local value="$2"
    OPENCLAW_TRACE_CONTEXT["$key"]="$value"
}

openclaw_trace_set_result() {
    local key="$1"
    local value="$2"
    OPENCLAW_TRACE_RESULTS["$key"]="$value"
}

openclaw_trace_add_step() {
    local step_id="$1"
    local step_type="$2"
    local step_desc="$3"

    OPENCLAW_TRACE_STEPS+=("$step_id")
    OPENCLAW_TRACE_STEP_STATUS["$step_id"]="pending"
    OPENCLAW_TRACE_STEP_DETAIL["$step_id"]="$step_desc"
    local _type_var="step_type_${step_id}"
    eval "OPENCLAW_TRACE_STEP_TYPE_${step_id//-/_}=\"$step_type\""

    openclaw_log_debug "Trace step added: ${step_id} (${step_type})"
}

openclaw_trace_update_step() {
    local step_id="$1"
    local status="$2"
    local detail="${3:-}"

    if [[ -z "${OPENCLAW_TRACE_STEP_STATUS[$step_id]+x}" ]]; then
        OPENCLAW_TRACE_STEPS+=("$step_id")
    fi

    OPENCLAW_TRACE_STEP_STATUS["$step_id"]="$status"

    if [[ -n "$detail" ]]; then
        OPENCLAW_TRACE_STEP_DETAIL["$step_id"]="$detail"
    fi

    local now
    now=$(openclaw_get_timestamp_ms)

    case "$status" in
        running|pending)
            if [[ -z "${OPENCLAW_TRACE_STEP_START[$step_id]+x}" ]]; then
                OPENCLAW_TRACE_STEP_START["$step_id"]="$now"
            fi
            ;;
        success|failed|skipped)
            OPENCLAW_TRACE_STEP_END["$step_id"]="$now"
            if [[ -z "${OPENCLAW_TRACE_STEP_START[$step_id]+x}" ]]; then
                OPENCLAW_TRACE_STEP_START["$step_id"]="$now"
            fi
            ;;
    esac

    openclaw_log_debug "Trace step ${step_id}: ${status}"
}

openclaw_trace_add_event() {
    local event_type="$1"
    local resource_type="$2"
    local resource_name="$3"
    local status="$4"
    shift 4
    local details=("$@")

    local timestamp
    timestamp=$(openclaw_get_timestamp_ms)

    local event_id
    event_id=$(openclaw_generate_id 8)

    local details_str=""
    if [[ ${#details[@]} -gt 0 ]]; then
        details_str=$(IFS="; "; echo "${details[*]}")
    fi

    local event_json
    event_json=$(cat <<EOF
  {
    "event_id": "${event_id}",
    "timestamp": "${timestamp}",
    "event_type": "${event_type}",
    "resource_type": "${resource_type}",
    "resource_name": "${resource_name}",
    "status": "${status}",
    "details": "${details_str}"
  }
EOF
)

    OPENCLAW_TRACE_EVENTS+=("$event_json")

    openclaw_log_debug "Trace event: ${event_type} ${resource_type}/${resource_name} [${status}]"
}

openclaw_trace_build_json() {
    local context_json="{"
    local first=true
    for key in "${!OPENCLAW_TRACE_CONTEXT[@]}"; do
        local escaped_value
        escaped_value=$(openclaw_json_escape "${OPENCLAW_TRACE_CONTEXT[$key]}")
        if $first; then
            first=false
        else
            context_json="${context_json},"
        fi
        context_json="${context_json} \"${key}\": \"${escaped_value}\""
    done
    context_json="${context_json} }"

    local results_json="{"
    first=true
    for key in "${!OPENCLAW_TRACE_RESULTS[@]}"; do
        local escaped_value
        escaped_value=$(openclaw_json_escape "${OPENCLAW_TRACE_RESULTS[$key]}")
        if $first; then
            first=false
        else
            results_json="${results_json},"
        fi
        results_json="${results_json} \"${key}\": \"${escaped_value}\""
    done
    results_json="${results_json} }"

    local steps_json="["
    first=true
    for step_id in "${OPENCLAW_TRACE_STEPS[@]}"; do
        if $first; then
            first=false
        else
            steps_json="${steps_json},"
        fi

        local step_type="unknown"
        local type_var="OPENCLAW_TRACE_STEP_TYPE_${step_id//-/_}"
        if [[ -n "${!type_var:-}" ]]; then
            step_type="${!type_var}"
        fi

        local status="${OPENCLAW_TRACE_STEP_STATUS[$step_id]:-unknown}"
        local detail="${OPENCLAW_TRACE_STEP_DETAIL[$step_id]:-}"
        local start="${OPENCLAW_TRACE_STEP_START[$step_id]:-}"
        local end="${OPENCLAW_TRACE_STEP_END[$step_id]:-}"

        local escaped_detail
        escaped_detail=$(openclaw_json_escape "$detail")

        steps_json=$(cat <<EOF
${steps_json}
    {
      "step_id": "${step_id}",
      "step_type": "${step_type}",
      "status": "${status}",
      "description": "${escaped_detail}",
      "start_time": "${start}",
      "end_time": "${end}"
    }
EOF
)
    done
    steps_json="${steps_json}
  ]"

    local events_json="["
    first=true
    for event in "${OPENCLAW_TRACE_EVENTS[@]}"; do
        if $first; then
            first=false
        else
            events_json="${events_json},"
        fi
        events_json="${events_json}
    ${event}"
    done
    events_json="${events_json}
  ]"

    local args_json="["
    first=true
    for arg in "${OPENCLAW_TRACE_ARGS[@]}"; do
        local escaped_arg
        escaped_arg=$(openclaw_json_escape "$arg")
        if $first; then
            first=false
        else
            args_json="${args_json}, "
        fi
        args_json="${args_json}\"${escaped_arg}\""
    done
    args_json="${args_json}]"

    cat <<EOF
{
  "trace_id": "${OPENCLAW_TRACE_ID}",
  "version": "${OPENCLAW_VERSION}",
  "command": "${OPENCLAW_TRACE_COMMAND}",
  "args": ${args_json},
  "start_time": "${OPENCLAW_TRACE_START_TIME}",
  "end_time": "${OPENCLAW_TRACE_END_TIME}",
  "status": "${OPENCLAW_TRACE_STATUS}",
  "exit_code": ${OPENCLAW_TRACE_EXIT_CODE},
  "context": ${context_json},
  "steps": ${steps_json},
  "events": ${events_json},
  "results": ${results_json}
}
EOF
}

openclaw_trace_save() {
    if [[ -z "${OPENCLAW_TRACE_ID}" ]]; then
        return 0
    fi

    if [[ ! -d "$OPENCLAW_TRACE_RECORD_DIR" ]]; then
        mkdir -p "$OPENCLAW_TRACE_RECORD_DIR" 2>/dev/null || {
            openclaw_log_warn "Cannot create trace record directory: ${OPENCLAW_TRACE_RECORD_DIR}"
            return 1
        }
    fi

    local raw_json_file
    raw_json_file=$(openclaw_tmpfile_create "trace_raw") || return 1

    openclaw_trace_build_json > "$raw_json_file" 2>/dev/null

    if command -v python3 &>/dev/null; then
        local format_script='
import json, sys

input_path = sys.argv[1]
output_path = sys.argv[2]

try:
    with open(input_path, "r") as f:
        data = json.load(f)
    with open(output_path, "w") as f:
        json.dump(data, f, indent=2)
except Exception:
    import shutil
    shutil.copyfile(input_path, output_path)
'
        if openclaw_process_json_script_file "$raw_json_file" "$format_script" 30 > /dev/null 2>&1; then
            local out_file
            out_file=$(openclaw_tmpfile_create "trace_fmt")
            openclaw_process_json_script_file "$raw_json_file" "$format_script" 30 > "$out_file" 2>/dev/null || true
            if [[ -s "$out_file" ]]; then
                cat "$out_file" > "$OPENCLAW_TRACE_RECORD_FILE"
            else
                cat "$raw_json_file" > "$OPENCLAW_TRACE_RECORD_FILE"
            fi
        else
            cat "$raw_json_file" > "$OPENCLAW_TRACE_RECORD_FILE"
        fi
    else
        cat "$raw_json_file" > "$OPENCLAW_TRACE_RECORD_FILE"
    fi

    openclaw_log_debug "Trace saved to: ${OPENCLAW_TRACE_RECORD_FILE}"

    if command -v python3 &>/dev/null && [[ -f "${OPENCLAW_MODELS_DIR}/execution_trace.py" ]]; then
        openclaw_trace_save_with_python "$raw_json_file" || true
    fi
}

openclaw_trace_save_with_python() {
    local json_input_file="$1"

    if [[ ! -f "$json_input_file" ]]; then
        openclaw_log_debug "Trace JSON file not found for Python save"
        return 1
    fi

    openclaw_exec_with_timeout 60 python3 "${OPENCLAW_MODELS_DIR}/execution_trace.py" \
        --trace-id "$OPENCLAW_TRACE_ID" \
        --output-dir "$OPENCLAW_TRACE_RECORD_DIR" \
        --input "$json_input_file" 2>/dev/null || true
}

openclaw_trace_get() {
    local trace_id="$1"

    if [[ -z "$trace_id" ]]; then
        trace_id="${OPENCLAW_TRACE_ID}"
    fi

    if [[ -z "$trace_id" ]]; then
        return 1
    fi

    local record_file
    record_file=$(openclaw_trace_find_record "$trace_id")

    if [[ -n "$record_file" && -f "$record_file" ]]; then
        cat "$record_file"
        return 0
    fi

    return 1
}

openclaw_trace_find_record() {
    local trace_id="$1"

    if [[ -z "$trace_id" ]]; then
        return 1
    fi

    if [[ ! -d "$OPENCLAW_RECORDS_DIR" ]]; then
        return 1
    fi

    local result_file
    result_file=$(openclaw_tmpfile_create "findres") || return 1

    openclaw_exec_with_timeout 30 find "$OPENCLAW_RECORDS_DIR" -name "trace_${trace_id}.json" -type f \
        >"$result_file" 2>/dev/null || true

    local first_line
    first_line=$(head -n 1 "$result_file" 2>/dev/null || true)

    if [[ -n "$first_line" ]]; then
        echo "$first_line"
        return 0
    fi
    return 1
}

openclaw_trace_list_records() {
    local limit="${1:-20}"
    local since="${2:-}"

    if [[ ! -d "$OPENCLAW_RECORDS_DIR" ]]; then
        return 0
    fi

    local find_out_file
    find_out_file=$(openclaw_tmpfile_create "findlist") || return 0
    local sort_out_file
    sort_out_file=$(openclaw_tmpfile_create "sortlist") || return 0

    local -a find_args=("$OPENCLAW_RECORDS_DIR" -name "trace_*.json" -type f)

    if [[ -n "$since" ]]; then
        local since_date
        since_date=$(date -d "$since" +%Y-%m-%d 2>/dev/null || echo "$since")
        find_args+=("-newermt" "$since_date")
    fi

    find_args+=("-printf" "%T@ %p\n")

    if ! openclaw_exec_with_timeout 60 find "${find_args[@]}" >"$find_out_file" 2>/dev/null; then
        openclaw_log_debug "find command timed out or failed"
    fi

    if [[ -s "$find_out_file" ]]; then
        sort -rn "$find_out_file" > "$sort_out_file" 2>/dev/null || true
        head -n "$limit" "$sort_out_file" 2>/dev/null || true
    fi

    return 0
}

openclaw_trace_cleanup_old() {
    local days="${1:-$OPENCLAW_RECORD_RETENTION_DAYS}"

    openclaw_log_info "Cleaning up trace records older than ${days} days..."

    if [[ ! -d "$OPENCLAW_RECORDS_DIR" ]]; then
        return 0
    fi

    local list_file
    list_file=$(openclaw_tmpfile_create "cleanlist") || return 0

    openclaw_exec_with_timeout 120 find "$OPENCLAW_RECORDS_DIR" -name "trace_*.json" -type f -mtime "+${days}" \
        >"$list_file" 2>/dev/null || true

    local deleted_count=0
    if [[ -s "$list_file" ]]; then
        while IFS= read -r filepath || [[ -n "$filepath" ]]; do
            [[ -z "$filepath" ]] && continue
            if rm -f "$filepath" 2>/dev/null; then
                deleted_count=$((deleted_count + 1))
            fi
        done < "$list_file"
    fi

    openclaw_log_info "Cleaned up ${deleted_count} old trace records"

    openclaw_exec_with_timeout 30 find "$OPENCLAW_RECORDS_DIR" -type d -empty -delete 2>/dev/null || true

    return 0
}

openclaw_cmd_audit() {
    local action="list"
    local limit=20
    local trace_id=""
    local format="text"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--list)
                action="list"
                shift
                ;;
            -s|--show)
                action="show"
                trace_id="$2"
                shift 2
                ;;
            --limit)
                limit="$2"
                shift 2
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            --since)
                shift 2
                ;;
            -h|--help)
                openclaw_help_audit
                return 0
                ;;
            -*)
                openclaw_log_error "Unknown option: $1"
                return 1
                ;;
            *)
                shift
                ;;
        esac
    done

    case "$action" in
        list)
            openclaw_audit_list "$limit" "$format"
            ;;
        show)
            openclaw_audit_show "$trace_id" "$format"
            ;;
        *)
            openclaw_log_error "Unknown action: ${action}"
            return 1
            ;;
    esac
}

openclaw_audit_list() {
    local limit="$1"
    local format="$2"

    openclaw_log_info "Listing recent audit records (limit: ${limit})"

    local list_file
    list_file=$(openclaw_tmpfile_create "auditlist") || return 0
    openclaw_trace_list_records "$limit" > "$list_file" 2>/dev/null || true

    if [[ ! -s "$list_file" ]]; then
        openclaw_log_info "No audit records found"
        return 0
    fi

    if [[ "$format" == "json" ]]; then
        echo "["
        local first=true
        local filepath
        while IFS= read -r _ filepath || [[ -n "$filepath" ]]; do
            [[ -z "$filepath" ]] && continue
            if [[ -f "$filepath" ]]; then
                if $first; then
                    first=false
                else
                    echo ","
                fi
                cat "$filepath"
            fi
        done < "$list_file"
        echo "]"
    else
        local summary_script='
import json, sys

list_path = sys.argv[1]
output_path = sys.argv[2]

lines = []

try:
    with open(list_path, "r") as f:
        for raw_line in f:
            raw_line = raw_line.rstrip("\n")
            if not raw_line:
                continue
            parts = raw_line.split(None, 1)
            if len(parts) < 2:
                continue
            filepath = parts[1]
            try:
                with open(filepath, "r") as jf:
                    data = json.load(jf)
                tid = data.get("trace_id", "?")
                cmd = data.get("command", "?")
                status = data.get("status", "?")
                ctx = data.get("context", {})
                ns = ctx.get("namespace", "default")
                start_time = data.get("start_time", "?")
                if len(start_time) >= 19:
                    start_time = start_time[11:19]
                lines.append(f"{tid}|{cmd}|{start_time}|{status}|{ns}")
            except Exception:
                continue
except Exception:
    pass

with open(output_path, "w") as f:
    f.write("\n".join(lines))
'
        local summary_file
        summary_file=$(openclaw_tmpfile_create "auditsum")
        openclaw_process_json_script_file "$list_file" "$summary_script" 60 > "$summary_file" 2>/dev/null || true

        printf "%-25s %-15s %-20s %-10s %s\n" "TRACE_ID" "COMMAND" "TIME" "STATUS" "NAMESPACE"
        printf "%-25s %-15s %-20s %-10s %s\n" "---" "---" "---" "---" "---"

        if [[ -s "$summary_file" ]]; then
            local tid cmd time status ns
            while IFS='|' read -r tid cmd time status ns || [[ -n "$tid" ]]; do
                [[ -z "$tid" ]] && continue
                printf "%-25s %-15s %-20s %-10s %s\n" "$tid" "$cmd" "$time" "$status" "$ns"
            done < "$summary_file"
        fi
    fi
}

openclaw_audit_show() {
    local trace_id="$1"
    local format="$2"

    if [[ -z "$trace_id" ]]; then
        openclaw_log_error "Trace ID required"
        return 1
    fi

    local record_file
    record_file=$(openclaw_trace_find_record "$trace_id")

    if [[ -z "$record_file" || ! -f "$record_file" ]]; then
        openclaw_log_error "Trace record not found: ${trace_id}"
        return 1
    fi

    if [[ "$format" == "json" ]]; then
        cat "$record_file"
    else
        if command -v python3 &>/dev/null; then
            python3 -m json.tool "$record_file" 2>/dev/null || cat "$record_file"
        else
            cat "$record_file"
        fi
    fi
}
