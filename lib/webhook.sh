#!/bin/bash

# Open Claw - Webhook Audit Module
# Audit layer: Synchronous webhook calls for all changes and audit events

OPENCLAW_WEBHOOK_LOADED=1

OPENCLAW_WEBHOOK_QUEUE=()
OPENCLAW_WEBHOOK_SUCCESS_COUNT=0
OPENCLAW_WEBHOOK_FAILED_COUNT=0

openclaw_webhook_is_enabled() {
    if [[ "${OPENCLAW_WEBHOOK_ENABLED:-true}" != "true" ]]; then
        return 1
    fi

    if [[ -z "${OPENCLAW_WEBHOOK_URL:-}" ]]; then
        return 1
    fi

    return 0
}

openclaw_webhook_send() {
    local event_type="$1"
    local resource_type="$2"
    local resource_name="$3"
    local status="$4"
    shift 4
    local details=("$@")

    if ! openclaw_webhook_is_enabled; then
        openclaw_log_debug "Webhook disabled, skipping audit event"
        return 0
    fi

    local timestamp
    timestamp=$(openclaw_get_timestamp_ms)
    local event_id
    event_id=$(openclaw_generate_id 12)
    local trace_id="${OPENCLAW_TRACE_ID:-unknown}"

    local details_json="{}"
    if [[ ${#details[@]} -gt 0 ]]; then
        details_json=$(openclaw_webhook_build_details_json "${details[@]}")
    fi

    local payload
    payload=$(cat <<EOF
{
  "event_id": "${event_id}",
  "trace_id": "${trace_id}",
  "timestamp": "${timestamp}",
  "source": "open-claw",
  "version": "${OPENCLAW_VERSION}",
  "event_type": "${event_type}",
  "resource": {
    "type": "${resource_type}",
    "name": "${resource_name}",
    "namespace": "${OPENCLAW_KUBECTL_NAMESPACE}"
  },
  "status": "${status}",
  "details": ${details_json},
  "operator": {
    "user": "${USER:-unknown}",
    "host": "${HOSTNAME:-unknown}"
  },
  "dry_run": ${OPENCLAW_DRY_RUN:-false}
}
EOF
)

    openclaw_log_debug "Sending webhook audit event: ${event_type} ${resource_type}/${resource_name} (${status})"
    openclaw_log_debug "Webhook payload: ${payload}"

    if openclaw_is_dry_run; then
        openclaw_log_info "[DRY-RUN] Would send webhook event: ${event_type}"
        return 0
    fi

    local http_code
    local response
    local curl_cmd

    if command -v curl &>/dev/null; then
        local curl_body_file
        curl_body_file=$(openclaw_tmpfile_create "curlbody")
        local curl_code_file
        curl_code_file=$(openclaw_tmpfile_create "curlcode")

        curl_cmd=(curl -s -o "$curl_body_file" -w "%{http_code}" -X POST \
            -H "Content-Type: application/json" \
            -H "X-Trace-ID: ${trace_id}" \
            -H "X-Event-ID: ${event_id}" \
            --max-time "${OPENCLAW_WEBHOOK_TIMEOUT}" \
            --connect-timeout 5 \
            -d "${payload}" \
            "${OPENCLAW_WEBHOOK_URL}")

        local curl_exit=1
        if openclaw_exec_with_timeout $((OPENCLAW_WEBHOOK_TIMEOUT + 5)) "${curl_cmd[@]}" > "$curl_code_file" 2>&1; then
            curl_exit=0
        else
            curl_exit=$?
        fi

        if [[ $curl_exit -ne 0 ]]; then
            local curl_err
            curl_err=$(cat "$curl_code_file" 2>/dev/null || echo "unknown error")
            openclaw_log_warn "Webhook request failed (curl exit: ${curl_exit}): ${curl_err}"
            OPENCLAW_WEBHOOK_FAILED_COUNT=$((OPENCLAW_WEBHOOK_FAILED_COUNT + 1))
            return 1
        fi

        http_code=$(cat "$curl_code_file" 2>/dev/null || echo "0")
        local body=""
        [[ -s "$curl_body_file" ]] && body=$(cat "$curl_body_file")

        if [[ "$http_code" =~ ^2 ]]; then
            openclaw_log_debug "Webhook delivered successfully (HTTP ${http_code})"
            OPENCLAW_WEBHOOK_SUCCESS_COUNT=$((OPENCLAW_WEBHOOK_SUCCESS_COUNT + 1))
            return 0
        else
            openclaw_log_warn "Webhook returned non-2xx status: ${http_code}"
            openclaw_log_debug "Webhook response body: ${body}"
            OPENCLAW_WEBHOOK_FAILED_COUNT=$((OPENCLAW_WEBHOOK_FAILED_COUNT + 1))
            return 1
        fi
    elif command -v python3 &>/dev/null; then
        local py_out_file
        py_out_file=$(openclaw_tmpfile_create "webhookpy")
        local py_script='
import json, urllib.request, urllib.error, sys, socket

url = sys.argv[1]
payload_file = sys.argv[2]
trace_id = sys.argv[3]
event_id = sys.argv[4]
timeout = int(sys.argv[5])

with open(payload_file, "r", encoding="utf-8") as f:
    data = f.read().encode("utf-8")

req = urllib.request.Request(url, data=data, method="POST")
req.add_header("Content-Type", "application/json")
req.add_header("X-Trace-ID", trace_id)
req.add_header("X-Event-ID", event_id)

try:
    resp = urllib.request.urlopen(req, timeout=timeout)
    print(f"STATUS:{resp.status}")
    print(resp.read().decode("utf-8")[:500])
    sys.exit(0)
except urllib.error.HTTPError as e:
    print(f"STATUS:{e.code}")
    print(e.read().decode("utf-8")[:500])
    sys.exit(1)
except Exception as e:
    print(f"ERROR:{str(e)}")
    sys.exit(1)
'
        local py_script_file
        py_script_file=$(openclaw_tmpfile_create "whscript.py")
        printf '%s' "$py_script" > "$py_script_file"

        local py_payload_file
        py_payload_file=$(openclaw_tmpfile_create "whpayload")
        printf '%s' "$payload" > "$py_payload_file"

        local py_exit=1
        if openclaw_exec_with_timeout $((OPENCLAW_WEBHOOK_TIMEOUT + 5)) \
            python3 "$py_script_file" \
            "$OPENCLAW_WEBHOOK_URL" \
            "$py_payload_file" \
            "$trace_id" \
            "$event_id" \
            "$OPENCLAW_WEBHOOK_TIMEOUT" \
            >"$py_out_file" 2>&1; then
            py_exit=0
        else
            py_exit=$?
        fi

        if [[ $py_exit -eq 0 ]]; then
            local status_line="?"
            if [[ -s "$py_out_file" ]]; then
                local raw_line
                while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
                    if [[ "$raw_line" == STATUS:* ]]; then
                        status_line="${raw_line#STATUS:}"
                        break
                    fi
                done < "$py_out_file"
            fi
            openclaw_log_debug "Webhook delivered (HTTP ${status_line})"
            OPENCLAW_WEBHOOK_SUCCESS_COUNT=$((OPENCLAW_WEBHOOK_SUCCESS_COUNT + 1))
            return 0
        else
            local python_result=""
            [[ -s "$py_out_file" ]] && python_result=$(cat "$py_out_file")
            openclaw_log_warn "Webhook request failed: ${python_result}"
            OPENCLAW_WEBHOOK_FAILED_COUNT=$((OPENCLAW_WEBHOOK_FAILED_COUNT + 1))
            return 1
        fi
    else
        openclaw_log_warn "Neither curl nor python3 available for webhook delivery"
        OPENCLAW_WEBHOOK_FAILED_COUNT=$((OPENCLAW_WEBHOOK_FAILED_COUNT + 1))
        return 1
    fi
}

openclaw_webhook_build_details_json() {
    local key_values=("$@")
    local json_parts=()

    for kv in "${key_values[@]}"; do
        if [[ "$kv" == *"="* ]]; then
            local key="${kv%%=*}"
            local value="${kv#*=}"
            local escaped_value
            escaped_value=$(openclaw_json_escape "$value")
            json_parts+=("\"${key}\":\"${escaped_value}\"")
        fi
    done

    if [[ ${#json_parts[@]} -eq 0 ]]; then
        echo "{}"
    else
        local joined
        joined=$(IFS=,; echo "${json_parts[*]}")
        echo "{${joined}}"
    fi
}

openclaw_audit_event() {
    local event_type="$1"
    local resource_type="$2"
    local resource_name="$3"
    local status="$4"
    shift 4
    local details=("$@")

    openclaw_log_debug "Audit event: ${event_type} ${resource_type}/${resource_name} [${status}]"

    openclaw_webhook_send "$event_type" "$resource_type" "$resource_name" "$status" "${details[@]}"

    if [[ -n "${OPENCLAW_TRACE_ID:-}" ]]; then
        openclaw_trace_add_event "$event_type" "$resource_type" "$resource_name" "$status" "${details[@]}"
    fi
}

openclaw_webhook_get_stats() {
    echo "success: ${OPENCLAW_WEBHOOK_SUCCESS_COUNT}"
    echo "failed: ${OPENCLAW_WEBHOOK_FAILED_COUNT}"
}

openclaw_webhook_check_connectivity() {
    if ! openclaw_webhook_is_enabled; then
        openclaw_log_info "Webhook is disabled or URL not configured"
        return 0
    fi

    openclaw_log_info "Checking webhook connectivity: ${OPENCLAW_WEBHOOK_URL}"

    if openclaw_webhook_send "health_check" "system" "open-claw" "info" "check=connectivity"; then
        openclaw_log_success "Webhook connectivity check passed"
        return 0
    else
        openclaw_log_error "Webhook connectivity check failed"
        return 1
    fi
}
