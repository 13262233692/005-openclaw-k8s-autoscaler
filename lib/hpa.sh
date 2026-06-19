#!/bin/bash

# Open Claw - HPA Management Module
# Business layer: HPA dynamic configuration based on custom CPU/Memory thresholds

OPENCLAW_HPA_LOADED=1

openclaw_cmd_hpa() {
    local subcommand="${1:-}"
    shift

    case "$subcommand" in
        list)
            openclaw_hpa_list "$@"
            ;;
        get)
            openclaw_hpa_get "$@"
            ;;
        set-threshold)
            openclaw_hpa_set_threshold "$@"
            ;;
        set-replicas)
            openclaw_hpa_set_replicas "$@"
            ;;
        disable)
            openclaw_hpa_disable "$@"
            ;;
        enable)
            openclaw_hpa_enable "$@"
            ;;
        -h|--help|help)
            openclaw_help_hpa
            return 0
            ;;
        "")
            openclaw_log_error "HPA subcommand required"
            openclaw_help_hpa
            return 1
            ;;
        *)
            openclaw_log_error "Unknown HPA subcommand: ${subcommand}"
            openclaw_help_hpa
            return 1
            ;;
    esac
}

openclaw_hpa_list() {
    local output_format="table"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                output_format="$2"
                shift 2
                ;;
            -h|--help)
                openclaw_help_hpa
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

    openclaw_log_info "Listing HPA configurations in namespace: ${OPENCLAW_KUBECTL_NAMESPACE}"

    local hpa_file
    hpa_file=$(openclaw_api_get_hpa_list_file) || {
        openclaw_log_error "Failed to get HPA list"
        return 1
    }

    local count_script='
import json, sys
data = json.load(open(sys.argv[1]))
print(len(data.get("items", [])))
'
    local hpa_count
    hpa_count=$(openclaw_process_json_script_file "$hpa_file" "$count_script" 30 2>/dev/null || echo "0")
    openclaw_trace_set_context "hpa_count" "$hpa_count"

    case "$output_format" in
        json)
            cat "$hpa_file"
            ;;
        table)
            openclaw_hpa_print_table_file "$hpa_file"
            ;;
        yaml)
            openclaw_log_warn "YAML output not implemented, using JSON"
            cat "$hpa_file"
            ;;
        *)
            openclaw_log_error "Unknown output format: ${output_format}"
            return 1
            ;;
    esac

    openclaw_audit_event "list" "hpa" "" "completed" "namespace=${OPENCLAW_KUBECTL_NAMESPACE}"

    return 0
}

openclaw_hpa_print_table_file() {
    local hpa_file="$1"

    local table_script='
import json, sys
data = json.load(open(sys.argv[1]))
items = data.get("items", [])
for item in items:
    name = item["metadata"]["name"]
    spec = item.get("spec", {})
    min_r = spec.get("minReplicas", "N/A")
    max_r = spec.get("maxReplicas", "N/A")

    cpu_target = "N/A"
    mem_target = "N/A"
    for m in spec.get("metrics", []):
        if m.get("type") == "Resource":
            res = m.get("resource", {})
            rname = res.get("name", "")
            target = res.get("target", {})
            if target.get("type") == "Utilization":
                val = target.get("averageUtilization", "N/A")
                if rname == "cpu":
                    cpu_target = str(val) + "%"
                elif rname == "memory":
                    mem_target = str(val) + "%"

    status = item.get("status", {})
    cur_replicas = status.get("currentReplicas", "N/A")
    desired_replicas = status.get("desiredReplicas", "N/A")

    print(f"{name}|{min_r}|{max_r}|{cpu_target}|{mem_target}|{cur_replicas}|{desired_replicas}")
'
    local items_file
    items_file=$(openclaw_tmpfile_create "hpatbl") || return 0
    openclaw_process_json_script_file "$hpa_file" "$table_script" 60 > "$items_file" 2>/dev/null || true

    printf "%-25s %-8s %-8s %-10s %-10s %-10s %-10s\n" \
        "NAME" "MIN" "MAX" "CPU%" "MEM%" "CURRENT" "DESIRED"
    printf "%-25s %-8s %-8s %-10s %-10s %-10s %-10s\n" \
        "---" "---" "---" "---" "---" "---" "---"

    if [[ -s "$items_file" ]]; then
        local name min_r max_r cpu_target mem_target cur desired
        while IFS='|' read -r name min_r max_r cpu_target mem_target cur desired || [[ -n "$name" ]]; do
            [[ -z "$name" ]] && continue
            printf "%-25s %-8s %-8s %-10s %-10s %-10s %-10s\n" \
                "$name" "$min_r" "$max_r" "$cpu_target" "$mem_target" "$cur" "$desired"
        done < "$items_file"
    fi
}

openclaw_hpa_get() {
    local hpa_name=""
    local output_format="table"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)
                hpa_name="$2"
                shift 2
                ;;
            -o|--output)
                output_format="$2"
                shift 2
                ;;
            -h|--help)
                openclaw_help_hpa
                return 0
                ;;
            -*)
                openclaw_log_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$hpa_name" ]]; then
                    hpa_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$hpa_name" ]]; then
        openclaw_log_error "HPA name required (-n <name>)"
        return 1
    fi

    openclaw_log_info "Getting HPA details: ${hpa_name}"

    openclaw_trace_add_step "get_hpa" "get_hpa_detail" "Retrieving HPA details"

    local hpa_file
    hpa_file=$(openclaw_kubectl_get_json_file "hpa" "$hpa_name") || {
        openclaw_trace_update_step "get_hpa" "failed" "HPA not found"
        openclaw_log_error "Failed to get HPA: ${hpa_name}"
        return 1
    }

    openclaw_trace_update_step "get_hpa" "success" "HPA retrieved"

    case "$output_format" in
        json)
            cat "$hpa_file"
            ;;
        table|text)
            openclaw_hpa_print_detail_file "$hpa_file"
            ;;
        *)
            openclaw_log_error "Unknown output format: ${output_format}"
            return 1
            ;;
    esac

    openclaw_audit_event "get" "hpa" "$hpa_name" "completed"

    return 0
}

openclaw_hpa_print_detail_file() {
    local hpa_file="$1"

    local name
    name=$(openclaw_extract_json_field_file "$hpa_file" ".metadata.name")
    local namespace
    namespace=$(openclaw_extract_json_field_file "$hpa_file" ".metadata.namespace")
    local min_replicas
    min_replicas=$(openclaw_extract_json_field_file "$hpa_file" ".spec.minReplicas")
    local max_replicas
    max_replicas=$(openclaw_extract_json_field_file "$hpa_file" ".spec.maxReplicas")
    local scale_target
    scale_target=$(openclaw_extract_json_field_file "$hpa_file" ".spec.scaleTargetRef.name")
    local scale_target_kind
    scale_target_kind=$(openclaw_extract_json_field_file "$hpa_file" ".spec.scaleTargetRef.kind")

    local current_replicas
    current_replicas=$(openclaw_extract_json_field_file "$hpa_file" ".status.currentReplicas")
    local desired_replicas
    desired_replicas=$(openclaw_extract_json_field_file "$hpa_file" ".status.desiredReplicas")

    echo ""
    echo "=== HPA: ${name} ==="
    echo "Namespace:        ${namespace}"
    echo "Scale Target:     ${scale_target_kind}/${scale_target}"
    echo "Min Replicas:     ${min_replicas}"
    echo "Max Replicas:     ${max_replicas}"
    echo "Current Replicas: ${current_replicas}"
    echo "Desired Replicas: ${desired_replicas}"
    echo ""
    echo "--- Thresholds ---"

    local detail_script='
import json, sys
data = json.load(open(sys.argv[1]))
metrics = data.get("spec", {}).get("metrics", [])
for m in metrics:
    if m.get("type") == "Resource":
        res = m.get("resource", {})
        rname = res.get("name", "")
        target = res.get("target", {})
        if target.get("type") == "Utilization":
            val = target.get("averageUtilization", "N/A")
            print(f"  {rname.upper()} Target:    {val}%")
'
    local out_file
    out_file=$(openclaw_tmpfile_create "hpadetail")
    if openclaw_process_json_script_file "$hpa_file" "$detail_script" 30 > "$out_file" 2>/dev/null && [[ -s "$out_file" ]]; then
        cat "$out_file"
    fi

    echo ""
    echo "--- Current Metrics ---"

    local curr_script='
import json, sys
data = json.load(open(sys.argv[1]))
metrics = data.get("status", {}).get("currentMetrics", [])
if not metrics:
    print("  (no current metrics available)")
else:
    for m in metrics:
        if m.get("type") == "Resource":
            res = m.get("resource", {})
            rname = res.get("name", "")
            val = res.get("current", {})
            avg_util = val.get("averageUtilization", "N/A")
            avg_val = val.get("averageValue", "N/A")
            if avg_util != "N/A":
                print(f"  {rname.upper()} Current:   {avg_util}%")
            else:
                print(f"  {rname.upper()} Current:   {avg_val}")
'
    local curr_out_file
    curr_out_file=$(openclaw_tmpfile_create "hpacurr")
    if openclaw_process_json_script_file "$hpa_file" "$curr_script" 30 > "$curr_out_file" 2>/dev/null; then
        if [[ -s "$curr_out_file" ]]; then
            cat "$curr_out_file"
        else
            echo "  (no current metrics available)"
        fi
    else
        echo "  (no current metrics available)"
    fi

    echo ""
}

openclaw_hpa_set_threshold() {
    local hpa_name=""
    local cpu_threshold=""
    local mem_threshold=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)
                hpa_name="$2"
                shift 2
                ;;
            --cpu)
                cpu_threshold="$2"
                shift 2
                ;;
            --memory)
                mem_threshold="$2"
                shift 2
                ;;
            -h|--help)
                openclaw_help_hpa
                return 0
                ;;
            -*)
                openclaw_log_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$hpa_name" ]]; then
                    hpa_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$hpa_name" ]]; then
        openclaw_log_error "HPA name required (-n <name>)"
        return 1
    fi

    if [[ -z "$cpu_threshold" && -z "$mem_threshold" ]]; then
        openclaw_log_error "At least one threshold required (--cpu or --memory)"
        return 1
    fi

    if [[ -n "$cpu_threshold" ]]; then
        if ! openclaw_validate_percent "$cpu_threshold"; then
            openclaw_log_error "Invalid CPU threshold: ${cpu_threshold} (must be 0-100)"
            return 1
        fi
    fi

    if [[ -n "$mem_threshold" ]]; then
        if ! openclaw_validate_percent "$mem_threshold"; then
            openclaw_log_error "Invalid memory threshold: ${mem_threshold} (must be 0-100)"
            return 1
        fi
    fi

    openclaw_log_info "Setting HPA thresholds for: ${hpa_name}"
    if [[ -n "$cpu_threshold" ]]; then
        openclaw_log_info "  CPU target:    ${cpu_threshold}%"
    fi
    if [[ -n "$mem_threshold" ]]; then
        openclaw_log_info "  Memory target: ${mem_threshold}%"
    fi

    openclaw_trace_set_context "hpa_name" "$hpa_name"
    openclaw_trace_set_context "cpu_threshold" "$cpu_threshold"
    openclaw_trace_set_context "memory_threshold" "$mem_threshold"

    openclaw_trace_add_step "verify_hpa" "verify_hpa" "Verifying HPA exists"
    if ! openclaw_api_get_hpa "$hpa_name" > /dev/null; then
        openclaw_trace_update_step "verify_hpa" "failed" "HPA not found"
        openclaw_log_error "HPA '${hpa_name}' not found"
        return 1
    fi
    openclaw_trace_update_step "verify_hpa" "success" "HPA exists"

    openclaw_trace_add_step "update_threshold" "update_hpa_threshold" "Updating HPA thresholds"
    if openclaw_api_update_hpa_threshold "$hpa_name" "$cpu_threshold" "$mem_threshold"; then
        openclaw_trace_update_step "update_threshold" "success" "Thresholds updated"
        openclaw_log_success "HPA ${hpa_name} thresholds updated successfully"
    else
        openclaw_trace_update_step "update_threshold" "failed" "Failed to update thresholds"
        openclaw_log_error "Failed to update HPA thresholds"
        return 1
    fi

    openclaw_audit_event "set_threshold" "hpa" "$hpa_name" "completed" \
        "cpu_threshold=${cpu_threshold}" "memory_threshold=${mem_threshold}"

    return 0
}

openclaw_hpa_set_replicas() {
    local hpa_name=""
    local min_replicas=""
    local max_replicas=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)
                hpa_name="$2"
                shift 2
                ;;
            --min|--min-replicas)
                min_replicas="$2"
                shift 2
                ;;
            --max|--max-replicas)
                max_replicas="$2"
                shift 2
                ;;
            -h|--help)
                openclaw_help_hpa
                return 0
                ;;
            -*)
                openclaw_log_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$hpa_name" ]]; then
                    hpa_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$hpa_name" ]]; then
        openclaw_log_error "HPA name required (-n <name>)"
        return 1
    fi

    if [[ -z "$min_replicas" && -z "$max_replicas" ]]; then
        openclaw_log_error "At least one replica bound required (--min or --max)"
        return 1
    fi

    if [[ -n "$min_replicas" ]]; then
        if ! openclaw_validate_positive_int "$min_replicas"; then
            openclaw_log_error "Invalid min replicas: ${min_replicas}"
            return 1
        fi
    fi

    if [[ -n "$max_replicas" ]]; then
        if ! openclaw_validate_positive_int "$max_replicas"; then
            openclaw_log_error "Invalid max replicas: ${max_replicas}"
            return 1
        fi
    fi

    if [[ -n "$min_replicas" && -n "$max_replicas" && "$min_replicas" -gt "$max_replicas" ]]; then
        openclaw_log_error "min replicas cannot be greater than max replicas"
        return 1
    fi

    openclaw_log_info "Setting HPA replica bounds for: ${hpa_name}"
    if [[ -n "$min_replicas" ]]; then
        openclaw_log_info "  Min replicas: ${min_replicas}"
    fi
    if [[ -n "$max_replicas" ]]; then
        openclaw_log_info "  Max replicas: ${max_replicas}"
    fi

    openclaw_trace_set_context "hpa_name" "$hpa_name"
    openclaw_trace_set_context "min_replicas" "$min_replicas"
    openclaw_trace_set_context "max_replicas" "$max_replicas"

    openclaw_trace_add_step "verify_hpa" "verify_hpa" "Verifying HPA exists"
    if ! openclaw_api_get_hpa "$hpa_name" > /dev/null; then
        openclaw_trace_update_step "verify_hpa" "failed" "HPA not found"
        openclaw_log_error "HPA '${hpa_name}' not found"
        return 1
    fi
    openclaw_trace_update_step "verify_hpa" "success" "HPA exists"

    openclaw_trace_add_step "update_replicas" "update_hpa_replicas" "Updating HPA replica bounds"
    if openclaw_api_update_hpa_replicas "$hpa_name" "$min_replicas" "$max_replicas"; then
        openclaw_trace_update_step "update_replicas" "success" "Replica bounds updated"
        openclaw_log_success "HPA ${hpa_name} replica bounds updated successfully"
    else
        openclaw_trace_update_step "update_replicas" "failed" "Failed to update replica bounds"
        openclaw_log_error "Failed to update HPA replica bounds"
        return 1
    fi

    openclaw_audit_event "set_replicas" "hpa" "$hpa_name" "completed" \
        "min_replicas=${min_replicas}" "max_replicas=${max_replicas}"

    return 0
}

openclaw_hpa_disable() {
    local hpa_name=""
    local replicas=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)
                hpa_name="$2"
                shift 2
                ;;
            --replicas)
                replicas="$2"
                shift 2
                ;;
            -h|--help)
                openclaw_help_hpa
                return 0
                ;;
            -*)
                openclaw_log_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$hpa_name" ]]; then
                    hpa_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$hpa_name" ]]; then
        openclaw_log_error "HPA name required (-n <name>)"
        return 1
    fi

    local hpa_json
    hpa_json=$(openclaw_api_get_hpa "$hpa_name") || {
        openclaw_log_error "HPA '${hpa_name}' not found"
        return 1
    }

    local scale_target
    scale_target=$(openclaw_extract_json_field "$hpa_json" ".spec.scaleTargetRef.name")
    local min_replicas
    min_replicas=$(openclaw_extract_json_field "$hpa_json" ".spec.minReplicas")

    if [[ -z "$replicas" ]]; then
        replicas="$min_replicas"
    fi

    if ! openclaw_validate_positive_int "$replicas"; then
        openclaw_log_error "Invalid replica count: ${replicas}"
        return 1
    fi

    openclaw_log_info "Disabling HPA: ${hpa_name} (setting ${scale_target} to ${replicas} replicas)"

    openclaw_trace_add_step "set_fixed_replicas" "set_fixed_replicas" "Setting fixed replica count"
    if openclaw_api_set_deployment_replicas "$scale_target" "$replicas"; then
        openclaw_trace_update_step "set_fixed_replicas" "success" "Fixed replicas set"
    else
        openclaw_trace_update_step "set_fixed_replicas" "failed" "Failed to set replicas"
        return 1
    fi

    openclaw_trace_add_step "delete_hpa" "delete_hpa" "Deleting HPA resource"

    if openclaw_is_dry_run; then
        openclaw_log_info "[DRY-RUN] Would delete HPA ${hpa_name}"
        openclaw_trace_update_step "delete_hpa" "success" "HPA would be deleted"
    else
        if openclaw_kubectl_exec "delete" "hpa" "$hpa_name"; then
            openclaw_trace_update_step "delete_hpa" "success" "HPA deleted"
            openclaw_log_success "HPA ${hpa_name} disabled (deleted)"
        else
            openclaw_trace_update_step "delete_hpa" "failed" "Failed to delete HPA"
            openclaw_log_error "Failed to delete HPA: ${OPENCLAW_KUBECTL_LAST_ERROR}"
            return 1
        fi
    fi

    openclaw_audit_event "disable" "hpa" "$hpa_name" "completed" \
        "target_deployment=${scale_target}" "fixed_replicas=${replicas}"

    return 0
}

openclaw_hpa_enable() {
    openclaw_log_warn "HPA enable (create) command requires deployment spec. Not implemented yet."
    openclaw_log_info "Use kubectl or the disable command's reverse operation."
    return 1
}
