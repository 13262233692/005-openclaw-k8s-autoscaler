#!/bin/bash

# Open Claw - Status Module
# Get cluster real-time metrics and status
#
# NOTE: This module has been refactored to eliminate pipeline deadlocks.
# Key changes:
#   - All JSON parsing done via temp files, never echo | python3 pipes
#   - Python processing scripts read from file, write to file
#   - Every python3 call wrapped with timeout enforcement
#   - Graceful fallback when JSON parsing fails (avoids hanging)

OPENCLAW_STATUS_LOADED=1

openclaw_cmd_status() {
    local resource_type="all"
    local output_format="table"
    local watch_mode=false
    local interval=5

    while [[ $# -gt 0 ]]; do
        case "$1" in
            nodes|pods|deployments|hpa|all)
                resource_type="$1"
                shift
                ;;
            -o|--output)
                output_format="$2"
                shift 2
                ;;
            -w|--watch)
                watch_mode=true
                shift
                ;;
            --interval)
                interval="$2"
                shift 2
                ;;
            -h|--help)
                openclaw_help_status
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

    if [[ "$watch_mode" == "true" ]]; then
        openclaw_status_watch "$resource_type" "$output_format" "$interval"
    else
        openclaw_status_show "$resource_type" "$output_format"
    fi

    return $?
}

openclaw_status_show() {
    local resource_type="$1"
    local output_format="$2"

    openclaw_trace_set_context "resource_type" "$resource_type"
    openclaw_trace_set_context "output_format" "$output_format"

    case "$resource_type" in
        all)
            openclaw_status_all "$output_format"
            ;;
        nodes)
            openclaw_status_nodes "$output_format"
            ;;
        pods)
            openclaw_status_pods "$output_format"
            ;;
        deployments)
            openclaw_status_deployments "$output_format"
            ;;
        hpa)
            openclaw_status_hpa "$output_format"
            ;;
        *)
            openclaw_log_error "Unknown resource type: ${resource_type}"
            return 1
            ;;
    esac
}

openclaw_status_all() {
    local output_format="$1"

    if [[ "$output_format" == "json" ]]; then
        local nodes_file pods_file depls_file hpa_file
        local nodes_json='{"items":[]}'
        local pods_json='{"items":[]}'
        local depls_json='{"items":[]}'
        local hpa_json='{"items":[]}'

        if nodes_file=$(openclaw_api_get_nodes_file 2>/dev/null) && [[ -f "$nodes_file" ]]; then
            nodes_json=$(cat "$nodes_file")
        fi
        if pods_file=$(openclaw_api_get_pods_file 2>/dev/null) && [[ -f "$pods_file" ]]; then
            pods_json=$(cat "$pods_file")
        fi
        if depls_file=$(openclaw_api_get_deployments_file 2>/dev/null) && [[ -f "$depls_file" ]]; then
            depls_json=$(cat "$depls_file")
        fi
        if hpa_file=$(openclaw_api_get_hpa_list_file 2>/dev/null) && [[ -f "$hpa_file" ]]; then
            hpa_json=$(cat "$hpa_file")
        fi

        cat <<EOF
{
  "timestamp": "$(openclaw_get_timestamp)",
  "namespace": "${OPENCLAW_KUBECTL_NAMESPACE}",
  "nodes": ${nodes_json},
  "pods": ${pods_json},
  "deployments": ${depls_json},
  "hpa": ${hpa_json}
}
EOF
    else
        echo ""
        echo "=== Cluster Status: ${OPENCLAW_KUBECTL_NAMESPACE} ==="
        echo "Timestamp: $(openclaw_get_timestamp)"
        echo ""

        openclaw_status_nodes "table"
        echo ""
        openclaw_status_deployments "table"
        echo ""
        openclaw_status_pods "table"
        echo ""
        openclaw_status_hpa "table"
    fi
}

openclaw_status_nodes() {
    local output_format="$1"

    openclaw_log_debug "Getting node status..."

    local json_file
    json_file=$(openclaw_api_get_nodes_file) || {
        openclaw_log_error "Failed to get node list"
        return 1
    }

    openclaw_trace_add_step "get_nodes" "get_nodes" "Retrieving node status"
    openclaw_trace_update_step "get_nodes" "success" "Node status retrieved"

    if [[ "$output_format" == "json" ]]; then
        cat "$json_file"
        return 0
    fi

    local count_script='
import json, sys

input_path = sys.argv[1]
output_path = sys.argv[2]

try:
    with open(input_path, "r") as f:
        data = json.load(f)
    count = len(data.get("items", []))
except Exception:
    count = 0

with open(output_path, "w") as f:
    f.write(str(count))
'

    local node_count
    node_count=$(openclaw_process_json_script_file "$json_file" "$count_script" 30 || echo "0")

    echo "--- Nodes (${node_count}) ---"

    local info_script='
import json, sys
from datetime import datetime, timezone

input_path = sys.argv[1]
output_path = sys.argv[2]

lines = []

try:
    with open(input_path, "r") as f:
        data = json.load(f)
    items = data.get("items", [])
except Exception as e:
    with open(output_path, "w") as f:
        f.write("")
    sys.exit(0)

for node in items:
    try:
        name = node.get("metadata", {}).get("name", "unknown")

        status = node.get("status", {})
        conditions = status.get("conditions", [])
        ready_status = "Unknown"
        for cond in conditions:
            if cond.get("type") == "Ready":
                if cond.get("status") == "True":
                    ready_status = "Ready"
                else:
                    ready_status = "NotReady"
                break

        capacity = status.get("capacity", {})
        cpu_cap = capacity.get("cpu", "N/A")
        mem_cap = capacity.get("memory", "N/A")

        allocatable = status.get("allocatable", {})
        cpu_alloc = allocatable.get("cpu", "N/A")
        mem_alloc = allocatable.get("memory", "N/A")

        roles = []
        labels = node.get("metadata", {}).get("labels", {})
        for key in labels:
            if key.startswith("node-role.kubernetes.io/"):
                role = key.replace("node-role.kubernetes.io/", "")
                roles.append(role)
        role_str = ",".join(roles) if roles else "<none>"

        lines.append(f"{name}|{ready_status}|{role_str}|{cpu_cap}|{mem_cap}")
    except Exception:
        continue

with open(output_path, "w") as f:
    f.write("\n".join(lines))
'

    local node_info
    node_info=$(openclaw_process_json_script_file "$json_file" "$info_script" 60 || echo "")

    printf "%-25s %-12s %-15s %-10s %-15s\n" \
        "NAME" "STATUS" "ROLES" "CPU" "MEMORY"
    printf "%-25s %-12s %-15s %-10s %-15s\n" \
        "---" "---" "---" "---" "---"

    if [[ -n "$node_info" ]]; then
        while IFS='|' read -r name status roles cpu mem || [[ -n "$name" ]]; do
            [[ -z "$name" ]] && continue
            printf "%-25s %-12s %-15s %-10s %-15s\n" \
                "$name" "$status" "$roles" "$cpu" "$mem"
        done <<< "$node_info"
    fi

    openclaw_audit_event "status" "nodes" "" "completed" "count=${node_count}"
}

openclaw_status_pods() {
    local output_format="$1"

    openclaw_log_debug "Getting pod status..."

    local json_file
    json_file=$(openclaw_api_get_pods_file) || {
        openclaw_log_error "Failed to get pod list"
        return 1
    }

    openclaw_trace_add_step "get_pods" "get_pods" "Retrieving pod status"
    openclaw_trace_update_step "get_pods" "success" "Pod status retrieved"

    if [[ "$output_format" == "json" ]]; then
        cat "$json_file"
        return 0
    fi

    local count_script='
import json, sys

input_path = sys.argv[1]
output_path = sys.argv[2]

try:
    with open(input_path, "r") as f:
        data = json.load(f)
    count = len(data.get("items", []))
except Exception:
    count = 0

with open(output_path, "w") as f:
    f.write(str(count))
'

    local pod_count
    pod_count=$(openclaw_process_json_script_file "$json_file" "$count_script" 30 || echo "0")

    echo "--- Pods (${pod_count}) ---"

    local info_script='
import json, sys
from datetime import datetime, timezone

input_path = sys.argv[1]
output_path = sys.argv[2]

lines = []

try:
    with open(input_path, "r") as f:
        data = json.load(f)
    items = data.get("items", [])
except Exception as e:
    with open(output_path, "w") as f:
        f.write("")
    sys.exit(0)

for pod in items:
    try:
        name = pod.get("metadata", {}).get("name", "unknown")
        status = pod.get("status", {})
        phase = status.get("phase", "Unknown")

        restarts = 0
        container_statuses = status.get("containerStatuses", [])
        for cs in container_statuses:
            restarts += cs.get("restartCount", 0)

        spec = pod.get("spec", {})
        node_name = spec.get("nodeName", "<none>")

        ready = "0/0"
        total_containers = len(spec.get("containers", []))
        ready_containers = 0
        for cs in container_statuses:
            if cs.get("ready", False):
                ready_containers += 1
        if total_containers > 0:
            ready = f"{ready_containers}/{total_containers}"

        age = "N/A"
        creation_ts = pod.get("metadata", {}).get("creationTimestamp")
        if creation_ts:
            try:
                created = datetime.fromisoformat(creation_ts.replace("Z", "+00:00"))
                now = datetime.now(timezone.utc)
                delta = now - created
                total_secs = int(delta.total_seconds())
                if total_secs < 60:
                    age = f"{total_secs}s"
                elif total_secs < 3600:
                    age = f"{total_secs // 60}m"
                elif total_secs < 86400:
                    age = f"{total_secs // 3600}h"
                else:
                    age = f"{total_secs // 86400}d"
            except Exception:
                pass

        lines.append(f"{name}|{ready}|{phase}|{restarts}|{age}|{node_name}")
    except Exception:
        continue

with open(output_path, "w") as f:
    f.write("\n".join(lines))
'

    local pod_info
    pod_info=$(openclaw_process_json_script_file "$json_file" "$info_script" 120 || echo "")

    printf "%-35s %-10s %-12s %-10s %-10s %-20s\n" \
        "NAME" "READY" "STATUS" "RESTARTS" "AGE" "NODE"
    printf "%-35s %-10s %-12s %-10s %-10s %-20s\n" \
        "---" "---" "---" "---" "---" "---"

    if [[ -n "$pod_info" ]]; then
        while IFS='|' read -r name ready status restarts age node || [[ -n "$name" ]]; do
            [[ -z "$name" ]] && continue
            printf "%-35s %-10s %-12s %-10s %-10s %-20s\n" \
                "$name" "$ready" "$status" "$restarts" "$age" "$node"
        done <<< "$pod_info"
    fi

    openclaw_audit_event "status" "pods" "" "completed" "count=${pod_count}"
}

openclaw_status_deployments() {
    local output_format="$1"

    openclaw_log_debug "Getting deployment status..."

    local json_file
    json_file=$(openclaw_api_get_deployments_file) || {
        openclaw_log_error "Failed to get deployment list"
        return 1
    }

    openclaw_trace_add_step "get_deployments" "get_deployments" "Retrieving deployment status"
    openclaw_trace_update_step "get_deployments" "success" "Deployment status retrieved"

    if [[ "$output_format" == "json" ]]; then
        cat "$json_file"
        return 0
    fi

    local count_script='
import json, sys

input_path = sys.argv[1]
output_path = sys.argv[2]

try:
    with open(input_path, "r") as f:
        data = json.load(f)
    count = len(data.get("items", []))
except Exception:
    count = 0

with open(output_path, "w") as f:
    f.write(str(count))
'

    local depl_count
    depl_count=$(openclaw_process_json_script_file "$json_file" "$count_script" 30 || echo "0")

    echo "--- Deployments (${depl_count}) ---"

    local info_script='
import json, sys
from datetime import datetime, timezone

input_path = sys.argv[1]
output_path = sys.argv[2]

lines = []

try:
    with open(input_path, "r") as f:
        data = json.load(f)
    items = data.get("items", [])
except Exception as e:
    with open(output_path, "w") as f:
        f.write("")
    sys.exit(0)

for depl in items:
    try:
        name = depl.get("metadata", {}).get("name", "unknown")
        spec = depl.get("spec", {})
        desired = spec.get("replicas", 0)

        status = depl.get("status", {})
        ready = status.get("readyReplicas", 0)
        updated = status.get("updatedReplicas", 0)
        available = status.get("availableReplicas", 0)

        age = "N/A"
        creation_ts = depl.get("metadata", {}).get("creationTimestamp")
        if creation_ts:
            try:
                created = datetime.fromisoformat(creation_ts.replace("Z", "+00:00"))
                now = datetime.now(timezone.utc)
                delta = now - created
                total_secs = int(delta.total_seconds())
                if total_secs < 60:
                    age = f"{total_secs}s"
                elif total_secs < 3600:
                    age = f"{total_secs // 60}m"
                elif total_secs < 86400:
                    age = f"{total_secs // 3600}h"
                else:
                    age = f"{total_secs // 86400}d"
            except Exception:
                pass

        lines.append(f"{name}|{ready}/{desired}|{updated}|{available}|{age}")
    except Exception:
        continue

with open(output_path, "w") as f:
    f.write("\n".join(lines))
'

    local depl_info
    depl_info=$(openclaw_process_json_script_file "$json_file" "$info_script" 60 || echo "")

    printf "%-30s %-12s %-10s %-12s %-10s\n" \
        "NAME" "READY" "UP-TO-DATE" "AVAILABLE" "AGE"
    printf "%-30s %-12s %-10s %-12s %-10s\n" \
        "---" "---" "---" "---" "---"

    if [[ -n "$depl_info" ]]; then
        while IFS='|' read -r name ready updated available age || [[ -n "$name" ]]; do
            [[ -z "$name" ]] && continue
            printf "%-30s %-12s %-10s %-12s %-10s\n" \
                "$name" "$ready" "$updated" "$available" "$age"
        done <<< "$depl_info"
    fi

    openclaw_audit_event "status" "deployments" "" "completed" "count=${depl_count}"
}

openclaw_status_hpa() {
    local output_format="$1"
    openclaw_hpa_list "$output_format"
}

openclaw_status_watch() {
    local resource_type="$1"
    local output_format="$2"
    local interval="$3"

    if ! openclaw_validate_positive_int "$interval"; then
        openclaw_log_error "Invalid interval: ${interval}"
        return 1
    fi

    openclaw_log_info "Watch mode: refreshing every ${interval}s (Ctrl+C to exit)"

    while true; do
        clear 2>/dev/null || printf "\033c"
        openclaw_status_show "$resource_type" "$output_format"
        local show_exit=$?
        echo ""
        echo "--- Refreshing every ${interval}s (Ctrl+C to exit) ---"

        openclaw_reap_zombies

        sleep "$interval"
    done
}
