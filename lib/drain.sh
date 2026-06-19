#!/bin/bash

OPENCLAW_DRAIN_LOADED=1

openclaw_cmd_drain() {
    local subcommand="${1:-}"
    shift

    case "$subcommand" in
        monitor)
            openclaw_drain_monitor "$@"
            ;;
        taint)
            openclaw_drain_taint_node "$@"
            ;;
        untaint)
            openclaw_drain_untaint_node "$@"
            ;;
        evict)
            openclaw_drain_evict_node "$@"
            ;;
        cordon)
            openclaw_drain_cordon "$@"
            ;;
        uncordon)
            openclaw_drain_uncordon "$@"
            ;;
        status)
            openclaw_drain_status "$@"
            ;;
        -h|--help|help)
            openclaw_help_drain
            return 0
            ;;
        "")
            openclaw_log_error "Drain subcommand required"
            openclaw_help_drain
            return 1
            ;;
        *)
            openclaw_log_error "Unknown drain subcommand: ${subcommand}"
            openclaw_help_drain
            return 1
            ;;
    esac
}

openclaw_drain_monitor() {
    local node_name=""
    local once=false
    local watch_mode=false
    local disk_threshold="$OPENCLAW_DRAIN_DISK_IO_THRESHOLD"
    local cpu_threshold="$OPENCLAW_DRAIN_CPU_THRESHOLD"
    local mem_threshold="$OPENCLAW_DRAIN_MEMORY_THRESHOLD"
    local auto_taint=false
    local auto_evict=false
    local skip_confirm=false
    local interval="$OPENCLAW_DRAIN_MONITOR_INTERVAL"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--node)
                node_name="$2"
                shift 2
                ;;
            --once)
                once=true
                shift
                ;;
            --watch)
                watch_mode=true
                shift
                ;;
            --disk-threshold)
                disk_threshold="$2"
                shift 2
                ;;
            --cpu-threshold)
                cpu_threshold="$2"
                shift 2
                ;;
            --memory-threshold)
                mem_threshold="$2"
                shift 2
                ;;
            --auto-taint)
                auto_taint=true
                shift
                ;;
            --auto-evict)
                auto_evict=true
                auto_taint=true
                shift
                ;;
            --interval)
                interval="$2"
                shift 2
                ;;
            -y|--yes)
                skip_confirm=true
                shift
                ;;
            -h|--help)
                openclaw_help_drain
                return 0
                ;;
            -*)
                openclaw_log_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$node_name" ]]; then
                    node_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$node_name" ]]; then
        openclaw_log_error "Node name required (-n <node-name>)"
        return 1
    fi

    if ! openclaw_validate_positive_int "$disk_threshold" || \
       ! openclaw_validate_positive_int "$cpu_threshold" || \
       ! openclaw_validate_positive_int "$mem_threshold"; then
        openclaw_log_error "Thresholds must be positive integers (0-100)"
        return 1
    fi

    openclaw_trace_set_context "node" "$node_name"
    openclaw_trace_set_context "disk_threshold" "$disk_threshold"
    openclaw_trace_set_context "cpu_threshold" "$cpu_threshold"
    openclaw_trace_set_context "mem_threshold" "$mem_threshold"

    if [[ "$auto_evict" == "true" ]]; then
        openclaw_log_info "Monitor mode: AUTO-EVICT (taint + evict on threshold breach)"
    elif [[ "$auto_taint" == "true" ]]; then
        openclaw_log_info "Monitor mode: AUTO-TAINT (taint on threshold breach)"
    else
        openclaw_log_info "Monitor mode: OBSERVE (report only, no automatic action)"
    fi

    openclaw_log_info "Monitoring node: ${node_name}"
    openclaw_log_info "Thresholds - Disk IO: ${disk_threshold}% | CPU: ${cpu_threshold}% | Memory: ${mem_threshold}%"

    local breach_count=0
    local consecutive_breach_required=3

    while true; do
        openclaw_trace_add_step "monitor_${node_name}" "check_pressure" "Checking resource pressure on ${node_name}"

        local pressure_result
        pressure_result=$(openclaw_drain_check_pressure "$node_name" "$disk_threshold" "$cpu_threshold" "$mem_threshold")
        local pressure_exit=$?

        if [[ $pressure_exit -eq 0 ]]; then
            local disk_pct cpu_pct mem_pct
            disk_pct=$(openclaw_drain_parse_pressure_field "$pressure_result" "disk")
            cpu_pct=$(openclaw_drain_parse_pressure_field "$pressure_result" "cpu")
            mem_pct=$(openclaw_drain_parse_pressure_field "$pressure_result" "memory")
            local conditions_str
            conditions_str=$(openclaw_drain_parse_pressure_field "$pressure_result" "conditions")

            local timestamp
            timestamp=$(openclaw_timestamp_iso)

            if [[ "$disk_pct" -ge "$disk_threshold" ]] || [[ "$cpu_pct" -ge "$cpu_threshold" ]] || [[ "$mem_pct" -ge "$mem_threshold" ]]; then
                breach_count=$((breach_count + 1))
                openclaw_log_warn "[${timestamp}] PRESSURE BREACH #${breach_count}/${consecutive_breach_required} on ${node_name}: Disk=${disk_pct}% CPU=${cpu_pct}% Mem=${mem_pct}% Conditions=[${conditions_str}]"

                if [[ $breach_count -ge $consecutive_breach_required ]]; then
                    openclaw_log_error "CRITICAL: Node ${node_name} has sustained resource pressure for ${consecutive_breach_required} consecutive checks"

                    if [[ "$auto_taint" == "true" ]]; then
                        openclaw_log_warn "Auto-taint triggered for node ${node_name}"
                        openclaw_audit_event "auto_taint" "node" "$node_name" "critical_pressure" "disk=${disk_pct}% cpu=${cpu_pct}% mem=${mem_pct}%"

                        if openclaw_drain_taint_node -n "$node_name" --key "$OPENCLAW_DRAIN_TAINT_KEY" --value "$OPENCLAW_DRAIN_TAINT_VALUE" --effect "$OPENCLAW_DRAIN_TAINT_EFFECT" -y; then
                            openclaw_trace_update_step "monitor_${node_name}" "success" "Node tainted with NoExecute"

                            if [[ "$auto_evict" == "true" ]]; then
                                openclaw_log_warn "Auto-evict triggered for node ${node_name}"
                                openclaw_audit_event "auto_evict" "node" "$node_name" "initiated" "taint_applied"

                                if openclaw_drain_evict_node -n "$node_name" -y; then
                                    openclaw_log_success "Auto-evict completed for node ${node_name}"
                                else
                                    openclaw_log_error "Auto-evict failed for node ${node_name}"
                                fi
                            fi
                        else
                            openclaw_trace_update_step "monitor_${node_name}" "failed" "Failed to taint node"
                        fi
                    fi

                    if [[ "$watch_mode" != "true" ]] || [[ "$auto_evict" == "true" ]]; then
                        break
                    fi
                    breach_count=0
                fi
            else
                if [[ $breach_count -gt 0 ]]; then
                    openclaw_log_info "Pressure normalized on ${node_name} (was ${breach_count} breach(es)), resetting counter"
                fi
                breach_count=0
                openclaw_log_info "[${timestamp}] Node ${node_name} healthy: Disk=${disk_pct}% CPU=${cpu_pct}% Mem=${mem_pct}% Conditions=[${conditions_str}]"
            fi

            openclaw_trace_update_step "monitor_${node_name}" "success" "Pressure check completed"
        else
            openclaw_log_warn "Failed to check pressure on node ${node_name}"
            openclaw_trace_update_step "monitor_${node_name}" "failed" "Pressure check failed"
        fi

        if [[ "$once" == "true" ]]; then
            if [[ $breach_count -ge $consecutive_breach_required ]]; then
                return 1
            fi
            return 0
        fi

        if [[ "$watch_mode" != "true" ]]; then
            if [[ $breach_count -ge $consecutive_breach_required ]]; then
                return 1
            fi
            return 0
        fi

        sleep "$interval"
        openclaw_reap_zombies 2>/dev/null || true
    done
}

openclaw_drain_check_pressure() {
    local node_name="$1"
    local disk_threshold="$2"
    local cpu_threshold="$3"
    local mem_threshold="$4"

    local node_file
    node_file=$(openclaw_api_get_node_pressure_status_file "$node_name") || {
        openclaw_log_error "Failed to get node status for ${node_name}"
        return 1
    }

    local pressure_script='
import json, sys

input_path = sys.argv[1]
output_path = sys.argv[2]
disk_threshold = int(sys.argv[3])
cpu_threshold = int(sys.argv[4])
mem_threshold = int(sys.argv[5])

with open(input_path, "r") as f:
    data = json.load(f)

status = data.get("status", {})
conditions = status.get("conditions", [])

disk_pressure = "False"
mem_pressure = "False"
pid_pressure = "False"
ready = "Unknown"

for c in conditions:
    ctype = c.get("type", "")
    cstatus = c.get("status", "Unknown")
    if ctype == "DiskPressure":
        disk_pressure = cstatus
    elif ctype == "MemoryPressure":
        mem_pressure = cstatus
    elif ctype == "PIDPressure":
        pid_pressure = cstatus
    elif ctype == "Ready":
        ready = cstatus

allocatable = status.get("allocatable", {})
capacity = status.get("capacity", {})

cpu_pct = 0
mem_pct = 0
disk_pct = 0

try:
    cpu_alloc = allocatable.get("cpu", "0")
    cpu_cap = capacity.get("cpu", "0")
    if cpu_cap.endswith("m") and cpu_alloc.endswith("m"):
        cap_val = int(cpu_cap.rstrip("m"))
        alloc_val = int(cpu_alloc.rstrip("m"))
        if cap_val > 0:
            cpu_pct = int((1 - alloc_val / cap_val) * 100)
    elif cpu_cap and cpu_alloc:
        cap_val = int(float(cpu_cap))
        alloc_val = int(float(cpu_alloc))
        if cap_val > 0:
            cpu_pct = int((1 - alloc_val / cap_val) * 100)
except (ValueError, ZeroDivisionError):
    pass

try:
    mem_alloc = allocatable.get("memory", "0")
    mem_cap = capacity.get("memory", "0")

    def parse_mem(val):
        val = str(val)
        if val.endswith("Ki"):
            return int(val.rstrip("Ki"))
        elif val.endswith("Mi"):
            return int(val.rstrip("Mi")) * 1024
        elif val.endswith("Gi"):
            return int(val.rstrip("Gi")) * 1024 * 1024
        return int(val)

    cap_val = parse_mem(mem_cap)
    alloc_val = parse_mem(mem_alloc)
    if cap_val > 0:
        mem_pct = int((1 - alloc_val / cap_val) * 100)
except (ValueError, ZeroDivisionError):
    pass

try:
    storage_alloc = allocatable.get("ephemeral-storage", "0")
    storage_cap = capacity.get("ephemeral-storage", "0")

    def parse_storage(val):
        val = str(val)
        if val.endswith("Ki"):
            return int(val.rstrip("Ki"))
        elif val.endswith("Mi"):
            return int(val.rstrip("Mi")) * 1024
        elif val.endswith("Gi"):
            return int(val.rstrip("Gi")) * 1024 * 1024
        return int(val)

    cap_val = parse_storage(storage_cap)
    alloc_val = parse_storage(storage_alloc)
    if cap_val > 0:
        disk_pct = int((1 - alloc_val / cap_val) * 100)
except (ValueError, ZeroDivisionError):
    pass

if disk_pressure == "True":
    disk_pct = max(disk_pct, disk_threshold)
if mem_pressure == "True":
    mem_pct = max(mem_pct, mem_threshold)

cond_str = f"Ready={ready},DiskPressure={disk_pressure},MemoryPressure={mem_pressure},PIDPressure={pid_pressure}"

with open(output_path, "w") as f:
    f.write(f"disk={disk_pct}|cpu={cpu_pct}|memory={mem_pct}|conditions={cond_str}")
'
    local script_file
    script_file=$(openclaw_tmpfile_create "pressure_script.py")
    printf '%s' "$pressure_script" > "$script_file"

    local result_file
    result_file=$(openclaw_tmpfile_create "pressure_result")

    if openclaw_exec_with_timeout 30 python3 "$script_file" "$node_file" "$result_file" "$disk_threshold" "$cpu_threshold" "$mem_threshold" 2>/dev/null; then
        if [[ -s "$result_file" ]]; then
            cat "$result_file"
            return 0
        fi
    fi

    return 1
}

openclaw_drain_parse_pressure_field() {
    local input="$1"
    local field="$2"

    local -a parts
    IFS='|' read -ra parts <<< "$input"

    for part in "${parts[@]}"; do
        if [[ "$part" == "${field}="* ]]; then
            printf '%s' "${part#${field}=}"
            return 0
        fi
    done

    echo "0"
}

openclaw_drain_taint_node() {
    local node_name=""
    local taint_key="$OPENCLAW_DRAIN_TAINT_KEY"
    local taint_value="$OPENCLAW_DRAIN_TAINT_VALUE"
    local taint_effect="$OPENCLAW_DRAIN_TAINT_EFFECT"
    local skip_confirm=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--node)
                node_name="$2"
                shift 2
                ;;
            --key)
                taint_key="$2"
                shift 2
                ;;
            --value)
                taint_value="$2"
                shift 2
                ;;
            --effect)
                taint_effect="$2"
                shift 2
                ;;
            -y|--yes)
                skip_confirm=true
                shift
                ;;
            -h|--help)
                openclaw_help_drain
                return 0
                ;;
            *)
                if [[ -z "$node_name" ]]; then
                    node_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$node_name" ]]; then
        openclaw_log_error "Node name required (-n <node-name>)"
        return 1
    fi

    if [[ "$taint_effect" != "NoExecute" ]] && [[ "$taint_effect" != "NoSchedule" ]] && [[ "$taint_effect" != "PreferNoSchedule" ]]; then
        openclaw_log_error "Invalid taint effect: ${taint_effect}. Must be NoExecute, NoSchedule, or PreferNoSchedule"
        return 1
    fi

    openclaw_trace_add_step "taint_${node_name}" "add_taint" "Adding taint ${taint_key}=${taint_value}:${taint_effect} to ${node_name}"

    if [[ "$skip_confirm" != "true" ]]; then
        if ! openclaw_confirm_action "Taint node ${node_name} with ${taint_key}=${taint_value}:${taint_effect}?" "n"; then
            openclaw_log_info "Operation cancelled by user"
            return 0
        fi
    fi

    if openclaw_api_cordon_node "$node_name"; then
        openclaw_log_info "Node ${node_name} cordoned before applying taint"
    else
        openclaw_log_warn "Failed to cordon node ${node_name}, continuing with taint"
    fi

    if openclaw_api_taint_node "$node_name" "$taint_key" "$taint_value" "$taint_effect"; then
        openclaw_trace_update_step "taint_${node_name}" "success" "Taint applied"
        openclaw_audit_event "taint" "node" "$node_name" "completed" "key=${taint_key} value=${taint_value} effect=${taint_effect}"
        return 0
    else
        openclaw_trace_update_step "taint_${node_name}" "failed" "Failed to apply taint"
        return 1
    fi
}

openclaw_drain_untaint_node() {
    local node_name=""
    local taint_key="$OPENCLAW_DRAIN_TAINT_KEY"
    local taint_effect="$OPENCLAW_DRAIN_TAINT_EFFECT"
    local skip_confirm=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--node)
                node_name="$2"
                shift 2
                ;;
            --key)
                taint_key="$2"
                shift 2
                ;;
            --effect)
                taint_effect="$2"
                shift 2
                ;;
            -y|--yes)
                skip_confirm=true
                shift
                ;;
            -h|--help)
                openclaw_help_drain
                return 0
                ;;
            *)
                if [[ -z "$node_name" ]]; then
                    node_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$node_name" ]]; then
        openclaw_log_error "Node name required (-n <node-name>)"
        return 1
    fi

    openclaw_trace_add_step "untaint_${node_name}" "remove_taint" "Removing taint ${taint_key}:${taint_effect} from ${node_name}"

    if [[ "$skip_confirm" != "true" ]]; then
        if ! openclaw_confirm_action "Remove taint ${taint_key}:${taint_effect} from node ${node_name} and uncordon?" "n"; then
            openclaw_log_info "Operation cancelled by user"
            return 0
        fi
    fi

    if openclaw_api_untaint_node "$node_name" "$taint_key" "$taint_effect"; then
        openclaw_trace_update_step "untaint_${node_name}" "success" "Taint removed"

        if openclaw_api_uncordon_node "$node_name"; then
            openclaw_log_success "Node ${node_name} uncordoned and taint removed"
        else
            openclaw_log_warn "Taint removed but failed to uncordon node ${node_name}"
        fi

        openclaw_audit_event "untaint" "node" "$node_name" "completed" "key=${taint_key} effect=${taint_effect}"
        return 0
    else
        openclaw_trace_update_step "untaint_${node_name}" "failed" "Failed to remove taint"
        return 1
    fi
}

openclaw_drain_evict_node() {
    local node_name=""
    local grace_period="$OPENCLAW_DRAIN_GRACE_PERIOD"
    local pod_timeout="$OPENCLAW_DRAIN_POD_TIMEOUT"
    local batch_size="$OPENCLAW_DRAIN_EVICTION_BATCH_SIZE"
    local batch_interval="$OPENCLAW_DRAIN_EVICTION_INTERVAL"
    local sts_wait_interval="$OPENCLAW_DRAIN_STATEFULSET_WAIT_INTERVAL"
    local sts_ready_timeout="$OPENCLAW_DRAIN_STATEFULSET_READY_TIMEOUT"
    local skip_confirm=false
    local ignore_daemonsets=true
    local skip_confirm_flag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--node)
                node_name="$2"
                shift 2
                ;;
            --grace-period)
                grace_period="$2"
                shift 2
                ;;
            --pod-timeout)
                pod_timeout="$2"
                shift 2
                ;;
            --batch-size)
                batch_size="$2"
                shift 2
                ;;
            --batch-interval)
                batch_interval="$2"
                shift 2
                ;;
            --sts-wait-interval)
                sts_wait_interval="$2"
                shift 2
                ;;
            --sts-ready-timeout)
                sts_ready_timeout="$2"
                shift 2
                ;;
            --include-daemonsets)
                ignore_daemonsets=false
                shift
                ;;
            -y|--yes)
                skip_confirm=true
                shift
                ;;
            -h|--help)
                openclaw_help_drain
                return 0
                ;;
            *)
                if [[ -z "$node_name" ]]; then
                    node_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$node_name" ]]; then
        openclaw_log_error "Node name required (-n <node-name>)"
        return 1
    fi

    if ! openclaw_validate_positive_int "$grace_period" || \
       ! openclaw_validate_positive_int "$pod_timeout" || \
       ! openclaw_validate_positive_int "$batch_size"; then
        openclaw_log_error "Invalid numeric parameter"
        return 1
    fi

    openclaw_trace_add_step "evict_${node_name}" "drain_node" "Draining node ${node_name} with graceful eviction"
    openclaw_trace_set_context "node" "$node_name"
    openclaw_trace_set_context "grace_period" "$grace_period"

    openclaw_log_info "=== Node Drain: ${node_name} ==="
    openclaw_log_info "Grace period: ${grace_period}s | Pod timeout: ${pod_timeout}s | Batch: ${batch_size}"

    if ! openclaw_drain_ensure_tainted "$node_name"; then
        openclaw_log_warn "Node ${node_name} not tainted, applying default NoExecute taint first"
        if ! openclaw_api_taint_node "$node_name" "$OPENCLAW_DRAIN_TAINT_KEY" "$OPENCLAW_DRAIN_TAINT_VALUE" "$OPENCLAW_DRAIN_TAINT_EFFECT"; then
            openclaw_log_error "Failed to taint node ${node_name}, aborting drain"
            openclaw_trace_update_step "evict_${node_name}" "failed" "Failed to taint node"
            return 1
        fi
    fi

    if ! openclaw_api_cordon_node "$node_name"; then
        openclaw_log_warn "Failed to cordon node ${node_name}, continuing anyway"
    fi

    local pods_file
    pods_file=$(openclaw_api_get_pods_on_node_file "$node_name") || {
        openclaw_log_error "Failed to list pods on node ${node_name}"
        openclaw_trace_update_step "evict_${node_name}" "failed" "Cannot list pods"
        return 1
    }

    local classify_script='
import json, sys

input_path = sys.argv[1]
output_path = sys.argv[2]
ignore_ds = sys.argv[3].lower() == "true"

with open(input_path, "r") as f:
    data = json.load(f)

items = data.get("items", [])
statefulset_pods = []
daemonset_pods = []
standalone_pods = []

for pod in items:
    name = pod["metadata"]["name"]
    ns = pod["metadata"]["namespace"]

    phase = pod.get("status", {}).get("phase", "Unknown")
    if phase == "Succeeded" or phase == "Failed":
        continue

    owner_refs = pod.get("metadata", {}).get("ownerReferences", [])
    controller_kind = ""
    controller_name = ""
    for ref in owner_refs:
        if ref.get("controller", False):
            controller_kind = ref.get("kind", "")
            controller_name = ref.get("name", "")
            break

    tolerations = pod.get("spec", {}).get("tolerations", [])
    has_noexecute_tol = False
    for tol in tolerations:
        if tol.get("operator") == "Exists":
            has_noexecute_tol = True
            break
        if tol.get("key") == "" and tol.get("operator") == "Exists":
            has_noexecute_tol = True
            break

    entry = f"{ns}/{name}|{controller_kind}|{controller_name}|{str(has_noexecute_tol).lower()}"

    if controller_kind == "DaemonSet":
        daemonset_pods.append(entry)
    elif controller_kind == "StatefulSet":
        statefulset_pods.append(entry)
    else:
        standalone_pods.append(entry)

with open(output_path, "w") as f:
    f.write("===STATEFULSET===\n")
    f.write("\n".join(statefulset_pods) + "\n")
    f.write("===DAEMONSET===\n")
    f.write("\n".join(daemonset_pods) + "\n")
    f.write("===STANDALONE===\n")
    f.write("\n".join(standalone_pods) + "\n")
'
    local classify_script_file
    classify_script_file=$(openclaw_tmpfile_create "classify_script.py")
    printf '%s' "$classify_script" > "$classify_script_file"

    local classified_file
    classified_file=$(openclaw_tmpfile_create "classified_pods")

    if ! openclaw_exec_with_timeout 60 python3 "$classify_script_file" "$pods_file" "$classified_file" "$ignore_daemonsets" 2>/dev/null; then
        openclaw_log_error "Failed to classify pods on node ${node_name}"
        openclaw_trace_update_step "evict_${node_name}" "failed" "Pod classification failed"
        return 1
    fi

    local -a sts_pods=()
    local -a ds_pods=()
    local -a standalone_pods=()
    local current_section=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == "===STATEFULSET===" ]]; then
            current_section="sts"
            continue
        elif [[ "$line" == "===DAEMONSET===" ]]; then
            current_section="ds"
            continue
        elif [[ "$line" == "===STANDALONE===" ]]; then
            current_section="standalone"
            continue
        fi

        case "$current_section" in
            sts) sts_pods+=("$line") ;;
            ds) ds_pods+=("$line") ;;
            standalone) standalone_pods+=("$line") ;;
        esac
    done < "$classified_file"

    local total_count=$(( ${#sts_pods[@]} + ${#standalone_pods[@]} ))
    if [[ "$ignore_daemonsets" != "true" ]]; then
        total_count=$(( total_count + ${#ds_pods[@]} ))
    fi

    openclaw_log_info "Pod classification: ${#sts_pods[@]} StatefulSet | ${#ds_pods[@]} DaemonSet | ${#standalone_pods[@]} standalone"

    if [[ $total_count -eq 0 ]]; then
        openclaw_log_info "No evictable pods on node ${node_name}"
        openclaw_trace_update_step "evict_${node_name}" "success" "No pods to evict"
        openclaw_audit_event "evict" "node" "$node_name" "completed" "pods_evicted=0"
        return 0
    fi

    if [[ "$skip_confirm" != "true" ]]; then
        echo ""
        echo "Pods to be evicted from ${node_name}:"
        echo "  StatefulSet pods: ${#sts_pods[@]}"
        echo "  Standalone pods:  ${#standalone_pods[@]}"
        if [[ "$ignore_daemonsets" != "true" ]]; then
            echo "  DaemonSet pods:   ${#ds_pods[@]}"
        else
            echo "  DaemonSet pods:   ${#ds_pods[@]} (will be skipped)"
        fi
        echo "  Total evictable:  ${total_count}"
        echo ""

        if ! openclaw_confirm_action "Evict ${total_count} pod(s) from node ${node_name}?" "n"; then
            openclaw_log_info "Operation cancelled by user"
            return 0
        fi
    fi

    openclaw_audit_event "evict_start" "node" "$node_name" "initiated" "total=${total_count} sts=${#sts_pods[@]} standalone=${#standalone_pods[@]}"

    local evicted_count=0
    local failed_count=0
    local -a failed_pods=()
    local -a statefulsets_to_verify=()

    openclaw_log_info "--- Phase 1: Evicting standalone pods ---"
    openclaw_drain_evict_pod_batch standalone_pods "$grace_period" "$batch_size" "$batch_interval" evicted_count failed_count failed_pods

    openclaw_log_info "--- Phase 2: Evicting StatefulSet pods ---"
    local sts_evicted=0
    local sts_failed=0
    local -a sts_failed_pods=()

    for pod_entry in "${sts_pods[@]}"; do
        local pod_id controller_kind controller_name has_toleration
        IFS='|' read -r pod_id controller_kind controller_name has_toleration <<< "$pod_entry"

        local ns="${pod_id%%/*}"
        local pname="${pod_id#*/}"

        if [[ "$has_toleration" == "true" ]]; then
            openclaw_log_info "Pod ${ns}/${pname} has NoExecute toleration, skipping"
            continue
        fi

        openclaw_log_info "Evicting StatefulSet pod: ${ns}/${pname} (owner: ${controller_name})"

        local retry_count=0
        local max_retries=3
        local evict_ok=false

        while [[ $retry_count -lt $max_retries ]]; do
            local evict_result
            evict_result=$(openclaw_api_evict_pod "$pname" "$ns" "$grace_period")
            local evict_exit=$?

            if [[ $evict_exit -eq 0 ]]; then
                evict_ok=true
                break
            elif [[ $evict_exit -eq 2 ]]; then
                retry_count=$((retry_count + 1))
                openclaw_log_warn "Rate limited, waiting ${batch_interval}s before retry (${retry_count}/${max_retries})"
                sleep "$batch_interval"
            else
                break
            fi
        done

        if $evict_ok; then
            sts_evicted=$((sts_evicted + 1))
            evicted_count=$((evicted_count + 1))

            local already_tracked=false
            for tracked in "${statefulsets_to_verify[@]}"; do
                if [[ "$tracked" == "${ns}|${controller_name}" ]]; then
                    already_tracked=true
                    break
                fi
            done
            if ! $already_tracked; then
                statefulsets_to_verify+=("${ns}|${controller_name}")
            fi

            openclaw_log_debug "Waiting for pod termination: ${ns}/${pname}"
            if ! openclaw_drain_wait_pod_termination "$ns" "$pname" "$pod_timeout"; then
                openclaw_log_warn "Pod ${ns}/${pname} did not terminate within ${pod_timeout}s"
            fi
        else
            sts_failed=$((sts_failed + 1))
            failed_count=$((failed_count + 1))
            sts_failed_pods+=("$pod_id")
            openclaw_log_error "Failed to evict StatefulSet pod: ${ns}/${pname}"
        fi

        sleep "$batch_interval"
        openclaw_reap_zombies 2>/dev/null || true
    done

    if [[ "$ignore_daemonsets" != "true" ]]; then
        openclaw_log_info "--- Phase 3: Evicting DaemonSet pods ---"
        for pod_entry in "${ds_pods[@]}"; do
            local pod_id controller_kind controller_name has_toleration
            IFS='|' read -r pod_id controller_kind controller_name has_toleration <<< "$pod_entry"

            local ns="${pod_id%%/*}"
            local pname="${pod_id#*/}"

            openclaw_log_info "Evicting DaemonSet pod: ${ns}/${pname}"
            if openclaw_api_evict_pod "$pname" "$ns" "$grace_period"; then
                evicted_count=$((evicted_count + 1))
            else
                failed_count=$((failed_count + 1))
                failed_pods+=("$pod_id")
            fi

            sleep "$batch_interval"
        done
    else
        openclaw_log_info "--- Phase 3: Skipping DaemonSet pods (${#ds_pods[@]} pods) ---"
    fi

    openclaw_log_info "--- Phase 4: Verifying StatefulSet replicas are Ready ---"
    local sts_verify_ok=true

    for sts_entry in "${statefulsets_to_verify[@]}"; do
        local sts_ns="${sts_entry%%|*}"
        local sts_name="${sts_entry#*|}"

        openclaw_log_info "Verifying StatefulSet: ${sts_ns}/${sts_name}"

        if openclaw_drain_wait_statefulset_ready "$sts_name" "$sts_ns" "$sts_wait_interval" "$sts_ready_timeout"; then
            openclaw_log_success "StatefulSet ${sts_ns}/${sts_name} all replicas Ready"
        else
            openclaw_log_error "StatefulSet ${sts_ns}/${sts_name} verification FAILED"
            sts_verify_ok=false
        fi
    done

    echo ""
    openclaw_log_info "=== Drain Summary for ${node_name} ==="
    openclaw_log_info "  Evicted:  ${evicted_count}"
    openclaw_log_info "  Failed:   ${failed_count}"

    if [[ ${#failed_pods[@]} -gt 0 ]] || [[ ${#sts_failed_pods[@]} -gt 0 ]]; then
        openclaw_log_warn "  Failed pods:"
        for fp in "${failed_pods[@]}" "${sts_failed_pods[@]}"; do
            openclaw_log_warn "    - ${fp}"
        done
    fi

    if ! $sts_verify_ok; then
        openclaw_log_error "Some StatefulSet replicas did not become Ready within timeout"
        openclaw_trace_update_step "evict_${node_name}" "failed" "StatefulSet verification incomplete"
        openclaw_audit_event "evict" "node" "$node_name" "partial" "evicted=${evicted_count} failed=${failed_count} sts_verify=failed"
        return 1
    fi

    if [[ $failed_count -gt 0 ]]; then
        openclaw_log_warn "Drain completed with ${failed_count} failure(s)"
        openclaw_trace_update_step "evict_${node_name}" "partial" "Some evictions failed"
        openclaw_audit_event "evict" "node" "$node_name" "partial" "evicted=${evicted_count} failed=${failed_count}"
        return 1
    fi

    openclaw_log_success "Node ${node_name} drained successfully"
    openclaw_trace_update_step "evict_${node_name}" "success" "All pods evicted, StatefulSets verified"
    openclaw_audit_event "evict" "node" "$node_name" "completed" "evicted=${evicted_count} sts_verify=ok"
    return 0
}

openclaw_drain_evict_pod_batch() {
    local -n _pods_ref="$1"
    local grace_period="$2"
    local batch_size="$3"
    local batch_interval="$4"
    local -n _evicted_ref="$5"
    local -n _failed_ref="$6"
    local -n _failed_pods_ref="$7"

    local count=0

    for pod_entry in "${_pods_ref[@]}"; do
        local pod_id controller_kind controller_name has_toleration
        IFS='|' read -r pod_id controller_kind controller_name has_toleration <<< "$pod_entry"

        local ns="${pod_id%%/*}"
        local pname="${pod_id#*/}"

        if [[ "$has_toleration" == "true" ]]; then
            openclaw_log_debug "Pod ${ns}/${pname} has NoExecute toleration, skipping"
            continue
        fi

        local retry_count=0
        local max_retries=3
        local evict_ok=false

        while [[ $retry_count -lt $max_retries ]]; do
            local evict_result
            evict_result=$(openclaw_api_evict_pod "$pname" "$ns" "$grace_period")
            local evict_exit=$?

            if [[ $evict_exit -eq 0 ]]; then
                evict_ok=true
                break
            elif [[ $evict_exit -eq 2 ]]; then
                retry_count=$((retry_count + 1))
                openclaw_log_warn "Rate limited on ${ns}/${pname}, waiting ${batch_interval}s (${retry_count}/${max_retries})"
                sleep "$batch_interval"
            else
                break
            fi
        done

        if $evict_ok; then
            _evicted_ref=$((_evicted_ref + 1))
            count=$((count + 1))
            openclaw_log_debug "Waiting for pod termination: ${ns}/${pname}"
            if ! openclaw_drain_wait_pod_termination "$ns" "$pname" "$OPENCLAW_DRAIN_POD_TIMEOUT"; then
                openclaw_log_warn "Pod ${ns}/${pname} did not terminate within timeout"
            fi
        else
            _failed_ref=$((_failed_ref + 1))
            _failed_pods_ref+=("$pod_id")
            openclaw_log_error "Failed to evict pod: ${ns}/${pname}"
        fi

        if [[ $count -ge $batch_size ]]; then
            openclaw_log_debug "Batch of ${batch_size} evictions completed, waiting ${batch_interval}s"
            sleep "$batch_interval"
            count=0
            openclaw_reap_zombies 2>/dev/null || true
        fi
    done
}

openclaw_drain_wait_pod_termination() {
    local namespace="$1"
    local pod_name="$2"
    local timeout="$3"

    local elapsed=0
    local check_interval=5

    while [[ $elapsed -lt $timeout ]]; do
        local check_args=("get" "pod" "$pod_name" "--namespace=${namespace}" "-o" "jsonpath={.metadata.name}")
        if ! openclaw_kubectl_exec "${check_args[@]}" 2>/dev/null; then
            return 0
        fi

        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done

    return 1
}

openclaw_drain_wait_statefulset_ready() {
    local sts_name="$1"
    local namespace="$2"
    local interval="$3"
    local timeout="$4"

    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local sts_file
        sts_file=$(openclaw_api_get_statefulset_file "$sts_name" "$namespace") || {
            openclaw_log_debug "Failed to get StatefulSet ${namespace}/${sts_name}, retrying..."
            sleep "$interval"
            elapsed=$((elapsed + interval))
            continue
        }

        local verify_script='
import json, sys

input_path = sys.argv[1]
output_path = sys.argv[2]

with open(input_path, "r") as f:
    data = json.load(f)

spec_replicas = data.get("spec", {}).get("replicas", 0)
status = data.get("status", {})
ready_replicas = status.get("readyReplicas", 0)
current_replicas = status.get("currentReplicas", 0)
updated_replicas = status.get("updatedReplicas", 0)
collision_count = status.get("collisionCount", 0)

is_ready = (ready_replicas == spec_replicas and
            current_replicas == spec_replicas and
            updated_replicas == spec_replicas)

with open(output_path, "w") as f:
    f.write(f"spec={spec_replicas}|ready={ready_replicas}|current={current_replicas}|updated={updated_replicas}|is_ready={str(is_ready).lower()}")
'
        local vscript_file
        vscript_file=$(openclaw_tmpfile_create "sts_verify.py")
        printf '%s' "$verify_script" > "$vscript_file"

        local vresult_file
        vresult_file=$(openclaw_tmpfile_create "sts_vresult")

        if openclaw_exec_with_timeout 30 python3 "$vscript_file" "$sts_file" "$vresult_file" 2>/dev/null; then
            if [[ -s "$vresult_file" ]]; then
                local result_data
                result_data=$(cat "$vresult_file")
                local is_ready
                is_ready=$(openclaw_drain_parse_pressure_field "$result_data" "is_ready")

                if [[ "$is_ready" == "true" ]]; then
                    local spec_r ready_r
                    spec_r=$(openclaw_drain_parse_pressure_field "$result_data" "spec")
                    ready_r=$(openclaw_drain_parse_pressure_field "$result_data" "ready")
                    openclaw_log_info "StatefulSet ${namespace}/${sts_name}: ${ready_r}/${spec_r} replicas Ready"
                    return 0
                else
                    local spec_r ready_r current_r
                    spec_r=$(openclaw_drain_parse_pressure_field "$result_data" "spec")
                    ready_r=$(openclaw_drain_parse_pressure_field "$result_data" "ready")
                    current_r=$(openclaw_drain_parse_pressure_field "$result_data" "current")
                    openclaw_log_debug "StatefulSet ${namespace}/${sts_name}: ready=${ready_r} current=${current_r} spec=${spec_r}, waiting..."
                fi
            fi
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
        openclaw_reap_zombies 2>/dev/null || true
    done

    return 1
}

openclaw_drain_ensure_tainted() {
    local node_name="$1"

    local node_file
    node_file=$(openclaw_api_get_node_conditions_file "$node_name") || return 1

    local check_script='
import json, sys

input_path = sys.argv[1]
output_path = sys.argv[2]
taint_key = sys.argv[3]
taint_effect = sys.argv[4]

with open(input_path, "r") as f:
    data = json.load(f)

taints = data.get("spec", {}).get("taints", [])
found = False
for t in taints:
    if t.get("key") == taint_key and t.get("effect") == taint_effect:
        found = True
        break

with open(output_path, "w") as f:
    f.write(str(found).lower())
'
    local csfile
    csfile=$(openclaw_tmpfile_create "taint_check.py")
    printf '%s' "$check_script" > "$csfile"

    local crfile
    crfile=$(openclaw_tmpfile_create "taint_result")

    if openclaw_exec_with_timeout 30 python3 "$csfile" "$node_file" "$crfile" "$OPENCLAW_DRAIN_TAINT_KEY" "$OPENCLAW_DRAIN_TAINT_EFFECT" 2>/dev/null; then
        if [[ -s "$crfile" ]]; then
            local result
            result=$(cat "$crfile")
            if [[ "$result" == "true" ]]; then
                return 0
            fi
        fi
    fi

    return 1
}

openclaw_drain_cordon() {
    local node_name=""
    local skip_confirm=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--node)
                node_name="$2"
                shift 2
                ;;
            -y|--yes)
                skip_confirm=true
                shift
                ;;
            -h|--help)
                openclaw_help_drain
                return 0
                ;;
            *)
                if [[ -z "$node_name" ]]; then
                    node_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$node_name" ]]; then
        openclaw_log_error "Node name required (-n <node-name>)"
        return 1
    fi

    if [[ "$skip_confirm" != "true" ]]; then
        if ! openclaw_confirm_action "Cordon node ${node_name} (mark as unschedulable)?" "n"; then
            openclaw_log_info "Operation cancelled by user"
            return 0
        fi
    fi

    openclaw_trace_add_step "cordon_${node_name}" "cordon" "Cordoning node ${node_name}"

    if openclaw_api_cordon_node "$node_name"; then
        openclaw_trace_update_step "cordon_${node_name}" "success" "Node cordoned"
        openclaw_audit_event "cordon" "node" "$node_name" "completed"
        return 0
    else
        openclaw_trace_update_step "cordon_${node_name}" "failed" "Cordon failed"
        return 1
    fi
}

openclaw_drain_uncordon() {
    local node_name=""
    local skip_confirm=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--node)
                node_name="$2"
                shift 2
                ;;
            -y|--yes)
                skip_confirm=true
                shift
                ;;
            -h|--help)
                openclaw_help_drain
                return 0
                ;;
            *)
                if [[ -z "$node_name" ]]; then
                    node_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$node_name" ]]; then
        openclaw_log_error "Node name required (-n <node-name>)"
        return 1
    fi

    if [[ "$skip_confirm" != "true" ]]; then
        if ! openclaw_confirm_action "Uncordon node ${node_name} (mark as schedulable)?" "n"; then
            openclaw_log_info "Operation cancelled by user"
            return 0
        fi
    fi

    openclaw_trace_add_step "uncordon_${node_name}" "uncordon" "Uncordoning node ${node_name}"

    if openclaw_api_uncordon_node "$node_name"; then
        openclaw_trace_update_step "uncordon_${node_name}" "success" "Node uncordoned"
        openclaw_audit_event "uncordon" "node" "$node_name" "completed"
        return 0
    else
        openclaw_trace_update_step "uncordon_${node_name}" "failed" "Uncordon failed"
        return 1
    fi
}

openclaw_drain_status() {
    local node_name=""
    local output_format="text"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--node)
                node_name="$2"
                shift 2
                ;;
            -o|--output)
                output_format="$2"
                shift 2
                ;;
            -h|--help)
                openclaw_help_drain
                return 0
                ;;
            *)
                if [[ -z "$node_name" ]]; then
                    node_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$node_name" ]]; then
        openclaw_log_info "Listing drain status for all nodes"
        openclaw_drain_status_all "$output_format"
        return $?
    fi

    openclaw_log_info "Getting drain status for node: ${node_name}"

    local node_file
    node_file=$(openclaw_api_get_node_conditions_file "$node_name") || {
        openclaw_log_error "Failed to get node status for ${node_name}"
        return 1
    }

    local status_script='
import json, sys

input_path = sys.argv[1]
output_path = sys.argv[2]
taint_key_prefix = sys.argv[3]

with open(input_path, "r") as f:
    data = json.load(f)

name = data["metadata"]["name"]
spec = data.get("spec", {})
status = data.get("status", {})

unschedulable = spec.get("unschedulable", False)
taints = spec.get("taints", [])
conditions = status.get("conditions", [])
addresses = status.get("addresses", [])

custom_taints = []
other_taints = []
for t in taints:
    if t.get("key", "").startswith(taint_key_prefix) or t.get("key", "").startswith("openclaw.io"):
        custom_taints.append(t)
    else:
        other_taints.append(t)

cond_map = {}
for c in conditions:
    cond_map[c.get("type", "")] = c.get("status", "Unknown")

result = {
    "name": name,
    "unschedulable": unschedulable,
    "custom_taints": custom_taints,
    "other_taints": other_taints,
    "conditions": cond_map,
    "addresses": {a.get("type"): a.get("address") for a in addresses}
}

with open(output_path, "w") as f:
    json.dump(result, f, indent=2)
'
    local sscript_file
    sscript_file=$(openclaw_tmpfile_create "node_status.py")
    printf '%s' "$status_script" > "$sscript_file"

    local sresult_file
    sresult_file=$(openclaw_tmpfile_create "node_status_result")

    if ! openclaw_exec_with_timeout 30 python3 "$sscript_file" "$node_file" "$sresult_file" "openclaw.io" 2>/dev/null; then
        openclaw_log_error "Failed to parse node status for ${node_name}"
        return 1
    fi

    if [[ "$output_format" == "json" ]]; then
        cat "$sresult_file"
        return 0
    fi

    local display_script='
import json, sys

input_path = sys.argv[1]

with open(input_path, "r") as f:
    data = json.load(f)

name = data["name"]
unschedulable = data["unschedulable"]
custom_taints = data["custom_taints"]
other_taints = data["other_taints"]
conditions = data["conditions"]
addresses = data.get("addresses", {})

sched_status = "Schedulable"
if unschedulable:
    sched_status = "Unschedulable (Cordoned)"

has_noexecute = False
for t in custom_taints:
    if t.get("effect") == "NoExecute":
        has_noexecute = True

drain_status = "Normal"
if has_noexecute:
    drain_status = "DRAINING (NoExecute taint active)"
elif unschedulable:
    drain_status = "Cordoned"

print(f"")
print(f"=== Node Drain Status: {name} ===")
print(f"  Scheduling:       {sched_status}")
print(f"  Drain Status:     {drain_status}")
print(f"  Internal IP:      {addresses.get('InternalIP', 'N/A')}")
print(f"")
print(f"  --- Conditions ---")
for ctype in ["Ready", "DiskPressure", "MemoryPressure", "PIDPressure", "NetworkUnavailable"]:
    val = conditions.get(ctype, "Unknown")
    marker = ""
    if ctype == "Ready" and val == "True":
        marker = " [OK]"
    elif ctype != "Ready" and val == "True":
        marker = " [PRESSURE]"
    print(f"  {ctype:<22} {val}{marker}")

if custom_taints:
    print(f"")
    print(f"  --- Open Claw Taints ---")
    for t in custom_taints:
        print(f"  {t.get('key')}={t.get('value', '')}:{t.get('effect')}")
else:
    print(f"")
    print(f"  --- Open Claw Taints ---")
    print(f"  (none)")

if other_taints:
    print(f"")
    print(f"  --- Other Taints ---")
    for t in other_taints:
        print(f"  {t.get('key')}={t.get('value', '')}:{t.get('effect')}")
print(f"")
'
    local dscript_file
    dscript_file=$(openclaw_tmpfile_create "node_display.py")
    printf '%s' "$display_script" > "$dscript_file"

    openclaw_exec_with_timeout 30 python3 "$dscript_file" "$sresult_file" 2>/dev/null
}

openclaw_drain_status_all() {
    local output_format="${1:-text}"

    local nodes_file
    nodes_file=$(openclaw_api_list_all_nodes_file) || {
        openclaw_log_error "Failed to list cluster nodes"
        return 1
    }

    local list_script='
import json, sys

input_path = sys.argv[1]
output_path = sys.argv[2]
taint_key_prefix = sys.argv[3]

with open(input_path, "r") as f:
    data = json.load(f)

items = data.get("items", [])
lines = []

for node in items:
    name = node["metadata"]["name"]
    spec = node.get("spec", {})
    status = node.get("status", {})

    unschedulable = spec.get("unschedulable", False)
    taints = spec.get("taints", [])
    conditions = status.get("conditions", [])

    has_custom_taint = False
    custom_effect = ""
    for t in taints:
        if t.get("key", "").startswith(taint_key_prefix) or t.get("key", "").startswith("openclaw.io"):
            has_custom_taint = True
            custom_effect = t.get("effect", "")
            break

    ready = "Unknown"
    disk_p = "False"
    mem_p = "False"
    for c in conditions:
        ct = c.get("type", "")
        cs = c.get("status", "Unknown")
        if ct == "Ready":
            ready = cs
        elif ct == "DiskPressure":
            disk_p = cs
        elif ct == "MemoryPressure":
            mem_p = cs

    sched = "OK" if not unschedulable else "CORDONED"
    drain = "DRAINING" if has_custom_taint else ("CORDONED" if unschedulable else "Normal")

    lines.append(f"{name}|{sched}|{drain}|{ready}|{disk_p}|{mem_p}")

with open(output_path, "w") as f:
    f.write("\n".join(lines))
'
    local lscript_file
    lscript_file=$(openclaw_tmpfile_create "node_list.py")
    printf '%s' "$list_script" > "$lscript_file"

    local lresult_file
    lresult_file=$(openclaw_tmpfile_create "node_list_result")

    if ! openclaw_exec_with_timeout 60 python3 "$lscript_file" "$nodes_file" "$lresult_file" "openclaw.io" 2>/dev/null; then
        openclaw_log_error "Failed to parse node list"
        return 1
    fi

    if [[ "$output_format" == "json" ]]; then
        cat "$lresult_file"
        return 0
    fi

    printf "%-30s %-12s %-15s %-8s %-8s %-8s\n" "NODE" "SCHEDULING" "DRAIN STATUS" "READY" "DISK_P" "MEM_P"
    printf "%-30s %-12s %-15s %-8s %-8s %-8s\n" "---" "---" "---" "---" "---" "---"

    if [[ -s "$lresult_file" ]]; then
        local nname sched drain_st ready_st disk_p mem_p
        while IFS='|' read -r nname sched drain_st ready_st disk_p mem_p || [[ -n "$nname" ]]; do
            [[ -z "$nname" ]] && continue
            printf "%-30s %-12s %-15s %-8s %-8s %-8s\n" "$nname" "$sched" "$drain_st" "$ready_st" "$disk_p" "$mem_p"
        done < "$lresult_file"
    fi
}

openclaw_help_drain() {
    echo "Command: drain"
    echo "Node scheduling intervention and workload evacuation"
    echo ""
    echo "Usage:"
    echo "  openclaw drain <subcommand> [options]"
    echo ""
    echo "Subcommands:"
    echo "  monitor    Monitor node resource pressure signals"
    echo "  taint      Apply NoExecute taint to a node"
    echo "  untaint    Remove custom taint and uncordon a node"
    echo "  evict      Orchestrate graceful workload eviction from a node"
    echo "  cordon     Mark node as unschedulable"
    echo "  uncordon   Mark node as schedulable"
    echo "  status     Show node drain/taint status"
    echo ""
    echo "Monitor Options:"
    echo "  -n, --node <name>           Target node name"
    echo "      --once                  Check pressure once and exit"
    echo "      --watch                 Continuously monitor pressure"
    echo "      --disk-threshold <pct>  Disk I/O saturation threshold (default: ${OPENCLAW_DRAIN_DISK_IO_THRESHOLD})"
    echo "      --cpu-threshold <pct>   CPU utilization threshold (default: ${OPENCLAW_DRAIN_CPU_THRESHOLD})"
    echo "      --memory-threshold <pct> Memory utilization threshold (default: ${OPENCLAW_DRAIN_MEMORY_THRESHOLD})"
    echo "      --auto-taint            Automatically taint node on sustained pressure"
    echo "      --auto-evict            Automatically taint and evict on sustained pressure"
    echo "      --interval <sec>        Monitor check interval (default: ${OPENCLAW_DRAIN_MONITOR_INTERVAL})"
    echo "  -y, --yes                   Skip confirmation prompts"
    echo ""
    echo "Taint Options:"
    echo "  -n, --node <name>           Target node name"
    echo "      --key <key>             Taint key (default: ${OPENCLAW_DRAIN_TAINT_KEY})"
    echo "      --value <value>         Taint value (default: ${OPENCLAW_DRAIN_TAINT_VALUE})"
    echo "      --effect <effect>       Taint effect: NoExecute|NoSchedule|PreferNoSchedule (default: ${OPENCLAW_DRAIN_TAINT_EFFECT})"
    echo "  -y, --yes                   Skip confirmation"
    echo ""
    echo "Untaint Options:"
    echo "  -n, --node <name>           Target node name"
    echo "      --key <key>             Taint key to remove (default: ${OPENCLAW_DRAIN_TAINT_KEY})"
    echo "      --effect <effect>       Taint effect (default: ${OPENCLAW_DRAIN_TAINT_EFFECT})"
    echo "  -y, --yes                   Skip confirmation"
    echo ""
    echo "Evict Options:"
    echo "  -n, --node <name>           Target node name"
    echo "      --grace-period <sec>    Graceful termination period (default: ${OPENCLAW_DRAIN_GRACE_PERIOD})"
    echo "      --pod-timeout <sec>     Timeout for individual pod termination (default: ${OPENCLAW_DRAIN_POD_TIMEOUT})"
    echo "      --batch-size <num>      Number of concurrent evictions (default: ${OPENCLAW_DRAIN_EVICTION_BATCH_SIZE})"
    echo "      --batch-interval <sec>  Interval between eviction batches (default: ${OPENCLAW_DRAIN_EVICTION_INTERVAL})"
    echo "      --sts-wait-interval <sec>  StatefulSet ready check interval (default: ${OPENCLAW_DRAIN_STATEFULSET_WAIT_INTERVAL})"
    echo "      --sts-ready-timeout <sec>  StatefulSet ready timeout (default: ${OPENCLAW_DRAIN_STATEFULSET_READY_TIMEOUT})"
    echo "      --include-daemonsets    Also evict DaemonSet pods"
    echo "  -y, --yes                   Skip confirmation"
    echo ""
    echo "Status Options:"
    echo "  -n, --node <name>           Specific node (omit for all nodes)"
    echo "  -o, --output <format>       Output format: text|json (default: text)"
    echo ""
    echo "Examples:"
    echo "  openclaw drain monitor -n worker-01 --watch --auto-taint"
    echo "  openclaw drain taint -n worker-01 --effect NoExecute"
    echo "  openclaw drain evict -n worker-01 -y"
    echo "  openclaw drain untaint -n worker-01 -y"
    echo "  openclaw drain status -n worker-01"
    echo "  openclaw drain status"
}
