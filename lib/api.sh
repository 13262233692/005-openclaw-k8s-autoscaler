#!/bin/bash

# Open Claw - API Layer (Kubectl Wrapper & JSON Parser)
# Low-level communication module: wraps kubectl commands and parses JSON output
#
# NOTE: This module has been refactored to eliminate pipeline deadlocks.
# Key changes:
#   - All kubectl output written to temp files instead of captured in variables
#   - Strict timeout enforcement on every kubectl call
#   - Exit code verification with graceful fallback
#   - JSON validation performed from files, not piped stdin
#   - Last output retained in files for post-examination

OPENCLAW_API_LOADED=1

OPENCLAW_KUBECTL_LAST_OUTPUT=""
OPENCLAW_KUBECTL_LAST_ERROR=""
OPENCLAW_KUBECTL_LAST_EXIT_CODE=0
OPENCLAW_KUBECTL_LAST_OUTPUT_FILE=""
OPENCLAW_KUBECTL_LAST_ERROR_FILE=""
OPENCLAW_KUBECTL_TIMEOUT="${OPENCLAW_KUBECTL_TIMEOUT:-180}"

openclaw_kubectl_build_cmd() {
    local -a cmd=()
    cmd+=("$OPENCLAW_KUBECTL_BIN")

    if [[ -n "${OPENCLAW_KUBECONFIG:-}" ]]; then
        cmd+=("--kubeconfig=${OPENCLAW_KUBECONFIG}")
    fi

    if [[ -n "${OPENCLAW_KUBECTL_NAMESPACE:-}" ]]; then
        cmd+=("--namespace=${OPENCLAW_KUBECTL_NAMESPACE}")
    fi

    printf '%s\n' "${cmd[@]}"
}

openclaw_kubectl_exec() {
    local -a args=("$@")
    local base_cmd
    base_cmd=$(openclaw_kubectl_build_cmd)

    local -a full_cmd_arr=()
    while IFS= read -r part; do
        full_cmd_arr+=("$part")
    done <<< "$base_cmd"

    full_cmd_arr+=("${args[@]}")

    openclaw_log_debug "kubectl exec (timeout=${OPENCLAW_KUBECTL_TIMEOUT}s): ${full_cmd_arr[*]}"

    local stdout_file
    stdout_file=$(openclaw_tmpfile_create "kubectl_stdout") || return 1
    local stderr_file
    stderr_file=$(openclaw_tmpfile_create "kubectl_stderr") || return 1

    OPENCLAW_KUBECTL_LAST_OUTPUT_FILE="$stdout_file"
    OPENCLAW_KUBECTL_LAST_ERROR_FILE="$stderr_file"

    if openclaw_exec_with_timeout "$OPENCLAW_KUBECTL_TIMEOUT" "${full_cmd_arr[@]}"; then
        OPENCLAW_KUBECTL_LAST_EXIT_CODE=0
        OPENCLAW_KUBECTL_LAST_OUTPUT=""
        OPENCLAW_KUBECTL_LAST_ERROR=""

        if [[ -f "$stdout_file" ]]; then
            local output_size
            output_size=$(wc -c < "$stdout_file" 2>/dev/null || echo "0")
            if [[ "$output_size" -lt 1048576 ]]; then
                OPENCLAW_KUBECTL_LAST_OUTPUT=$(cat "$stdout_file" 2>/dev/null)
            fi
        fi
        return 0
    else
        OPENCLAW_KUBECTL_LAST_EXIT_CODE=$OPENCLAW_LAST_EXIT_CODE
        OPENCLAW_KUBECTL_LAST_OUTPUT=""
        OPENCLAW_KUBECTL_LAST_ERROR=""

        if [[ -f "$stderr_file" ]]; then
            local err_size
            err_size=$(wc -c < "$stderr_file" 2>/dev/null || echo "0")
            if [[ "$err_size" -lt 262144 ]]; then
                OPENCLAW_KUBECTL_LAST_ERROR=$(cat "$stderr_file" 2>/dev/null)
            else
                OPENCLAW_KUBECTL_LAST_ERROR="<error output too large, see file: ${stderr_file}>"
            fi
        fi

        if [[ -f "$stdout_file" ]]; then
            local out_size
            out_size=$(wc -c < "$stdout_file" 2>/dev/null || echo "0")
            if [[ "$out_size" -lt 262144 ]]; then
                OPENCLAW_KUBECTL_LAST_OUTPUT=$(cat "$stdout_file" 2>/dev/null)
            fi
        fi

        openclaw_log_debug "kubectl failed (exit=${OPENCLAW_KUBECTL_LAST_EXIT_CODE}): ${OPENCLAW_KUBECTL_LAST_ERROR}"
        return $OPENCLAW_KUBECTL_LAST_EXIT_CODE
    fi
}

openclaw_kubectl_get_last_output_file() {
    echo "$OPENCLAW_KUBECTL_LAST_OUTPUT_FILE"
}

openclaw_kubectl_get_last_error_file() {
    echo "$OPENCLAW_KUBECTL_LAST_ERROR_FILE"
}

openclaw_kubectl_get_json() {
    local resource="$1"
    local name="${2:-}"
    local -a extra_args=()
    local i
    for ((i = 3; i <= $#; i++)); do
        extra_args+=("${!i}")
    done

    local -a args=("get" "$resource" "-o" "json")

    if [[ -n "$name" ]]; then
        args+=("$name")
    fi

    if [[ ${#extra_args[@]} -gt 0 ]]; then
        args+=("${extra_args[@]}")
    fi

    if openclaw_kubectl_exec "${args[@]}"; then
        local out_file
        out_file=$(openclaw_kubectl_get_last_output_file)

        if [[ -f "$out_file" ]]; then
            if openclaw_is_valid_json_file "$out_file"; then
                cat "$out_file"
                return 0
            else
                local err_details
                err_details=$(head -c 500 "$out_file" 2>/dev/null || true)
                openclaw_log_error "kubectl returned non-JSON output for ${resource}/${name:-}"
                openclaw_log_debug "First 500 bytes of output: ${err_details}"
                return 1
            fi
        else
            openclaw_log_error "kubectl output file not found after successful call"
            return 1
        fi
    else
        openclaw_log_error "kubectl get ${resource} ${name:-} failed (exit=${OPENCLAW_KUBECTL_LAST_EXIT_CODE})"
        return 1
    fi
}

openclaw_kubectl_get_json_file() {
    local resource="$1"
    local name="${2:-}"
    shift 2
    local -a extra_args=("$@")

    local -a args=("get" "$resource" "-o" "json")

    if [[ -n "$name" ]]; then
        args+=("$name")
    fi

    if [[ ${#extra_args[@]} -gt 0 ]]; then
        args+=("${extra_args[@]}")
    fi

    if openclaw_kubectl_exec "${args[@]}"; then
        local out_file
        out_file=$(openclaw_kubectl_get_last_output_file)

        if [[ -f "$out_file" ]]; then
            if openclaw_is_valid_json_file "$out_file"; then
                echo "$out_file"
                return 0
            else
                local err_details
                err_details=$(head -c 500 "$out_file" 2>/dev/null || true)
                openclaw_log_error "kubectl returned non-JSON output for ${resource}/${name:-}"
                openclaw_log_debug "First 500 bytes of output: ${err_details}"
                return 1
            fi
        else
            openclaw_log_error "kubectl output file not found after successful call"
            return 1
        fi
    else
        openclaw_log_error "kubectl get ${resource} ${name:-} failed (exit=${OPENCLAW_KUBECTL_LAST_EXIT_CODE})"
        return 1
    fi
}

openclaw_kubectl_patch() {
    local resource="$1"
    local name="$2"
    local patch_json="$3"
    local patch_type="${4:-strategic}"

    openclaw_log_debug "Patching ${resource}/${name} with type ${patch_type}"

    local patch_file
    patch_file=$(openclaw_tmpfile_create "patch") || return 1
    printf '%s' "$patch_json" > "$patch_file" 2>/dev/null

    local -a args=("patch" "$resource" "$name" "--type=${patch_type}" "--patch-file=${patch_file}")

    if openclaw_is_dry_run; then
        openclaw_log_info "[DRY-RUN] Would patch ${resource}/${name}"
        openclaw_log_debug "[DRY-RUN] Patch: ${patch_json}"
        return 0
    fi

    if openclaw_kubectl_exec "${args[@]}"; then
        return 0
    else
        openclaw_log_error "Failed to patch ${resource}/${name}: ${OPENCLAW_KUBECTL_LAST_ERROR}"
        return 1
    fi
}

openclaw_api_check_cluster() {
    openclaw_log_debug "Checking cluster connectivity..."

    if openclaw_kubectl_exec "version" "--short"; then
        openclaw_log_debug "Cluster connection successful"
        return 0
    else
        openclaw_log_error "Cannot connect to Kubernetes cluster"
        openclaw_log_error "${OPENCLAW_KUBECTL_LAST_ERROR}"
        return 1
    fi
}

openclaw_api_get_nodes() {
    openclaw_kubectl_get_json "nodes"
}

openclaw_api_get_nodes_file() {
    openclaw_kubectl_get_json_file "nodes"
}

openclaw_api_get_node_status() {
    local node_name="$1"
    openclaw_kubectl_get_json "nodes" "$node_name"
}

openclaw_api_get_pods() {
    local selector="${1:-}"
    local -a extra_args=()

    if [[ -n "$selector" ]]; then
        extra_args+=("--selector=${selector}")
    fi

    openclaw_kubectl_get_json "pods" "" "${extra_args[@]}"
}

openclaw_api_get_pods_file() {
    local selector="${1:-}"
    local -a extra_args=()

    if [[ -n "$selector" ]]; then
        extra_args+=("--selector=${selector}")
    fi

    openclaw_kubectl_get_json_file "pods" "" "${extra_args[@]}"
}

openclaw_api_get_pod_status() {
    local pod_name="$1"
    openclaw_kubectl_get_json "pods" "$pod_name"
}

openclaw_api_get_deployments() {
    local selector="${1:-}"
    local -a extra_args=()

    if [[ -n "$selector" ]]; then
        extra_args+=("--selector=${selector}")
    fi

    openclaw_kubectl_get_json "deployments" "" "${extra_args[@]}"
}

openclaw_api_get_deployments_file() {
    local selector="${1:-}"
    local -a extra_args=()

    if [[ -n "$selector" ]]; then
        extra_args+=("--selector=${selector}")
    fi

    openclaw_kubectl_get_json_file "deployments" "" "${extra_args[@]}"
}

openclaw_api_get_deployment() {
    local deploy_name="$1"
    openclaw_kubectl_get_json "deployments" "$deploy_name"
}

openclaw_api_get_hpa_list() {
    openclaw_kubectl_get_json "horizontalpodautoscalers"
}

openclaw_api_get_hpa_list_file() {
    openclaw_kubectl_get_json_file "horizontalpodautoscalers"
}

openclaw_api_get_hpa() {
    local hpa_name="$1"
    openclaw_kubectl_get_json "horizontalpodautoscalers" "$hpa_name"
}

openclaw_api_get_metrics_pods() {
    local selector="${1:-}"
    local -a extra_args=()

    if [[ -n "$selector" ]]; then
        extra_args+=("--selector=${selector}")
    fi

    openclaw_kubectl_get_json "pods" "" "${extra_args[@]}" "--subresource=metrics"
}

openclaw_api_get_pod_metrics() {
    local pod_name="$1"
    openclaw_kubectl_get_json "pods" "$pod_name" "--subresource=metrics"
}

openclaw_api_get_deployment_replicas() {
    local deploy_name="$1"
    local json_file
    json_file=$(openclaw_kubectl_get_json_file "deployments" "$deploy_name") || return 1
    openclaw_extract_json_field_file "$json_file" ".spec.replicas"
}

openclaw_api_get_deployment_ready_replicas() {
    local deploy_name="$1"
    local json_file
    json_file=$(openclaw_kubectl_get_json_file "deployments" "$deploy_name") || return 1
    openclaw_extract_json_field_file "$json_file" ".status.readyReplicas"
}

openclaw_api_set_deployment_replicas() {
    local deploy_name="$1"
    local replicas="$2"

    local patch_json="{\"spec\":{\"replicas\":${replicas}}}"

    openclaw_log_info "Setting deployment ${deploy_name} replicas to ${replicas}"

    if openclaw_kubectl_patch "deployment" "$deploy_name" "$patch_json"; then
        openclaw_log_success "Deployment ${deploy_name} replicas updated to ${replicas}"
        return 0
    else
        return 1
    fi
}

openclaw_api_restart_deployment() {
    local deploy_name="$1"
    local grace_period="${2:-}"

    openclaw_log_info "Restarting deployment: ${deploy_name}"

    local -a args=("rollout" "restart" "deployment" "$deploy_name")

    if openclaw_is_dry_run; then
        openclaw_log_info "[DRY-RUN] Would restart deployment ${deploy_name}"
        return 0
    fi

    if openclaw_kubectl_exec "${args[@]}"; then
        openclaw_log_success "Deployment ${deploy_name} restart initiated"
        return 0
    else
        openclaw_log_error "Failed to restart deployment ${deploy_name}: ${OPENCLAW_KUBECTL_LAST_ERROR}"
        return 1
    fi
}

openclaw_api_deployment_rollout_status() {
    local deploy_name="$1"
    local timeout="${2:-300s}"

    local -a args=("rollout" "status" "deployment" "$deploy_name" "--timeout=${timeout}")

    if openclaw_kubectl_exec "${args[@]}"; then
        return 0
    else
        return 1
    fi
}

openclaw_api_update_hpa_threshold() {
    local hpa_name="$1"
    local cpu_threshold="${2:-}"
    local mem_threshold="${3:-}"

    local metrics_json=""
    local -a metrics_parts=()

    if [[ -n "$cpu_threshold" ]]; then
        metrics_parts+=("{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"target\":{\"type\":\"Utilization\",\"averageUtilization\":${cpu_threshold}}}}")
    fi

    if [[ -n "$mem_threshold" ]]; then
        metrics_parts+=("{\"type\":\"Resource\",\"resource\":{\"name\":\"memory\",\"target\":{\"type\":\"Utilization\",\"averageUtilization\":${mem_threshold}}}}")
    fi

    if [[ ${#metrics_parts[@]} -eq 0 ]]; then
        openclaw_log_error "No threshold specified (cpu or memory required)"
        return 1
    fi

    local metrics_joined
    metrics_joined=$(IFS=,; echo "${metrics_parts[*]}")
    metrics_json="[${metrics_joined}]"

    local patch_json="{\"spec\":{\"metrics\":${metrics_json}}}"

    openclaw_log_info "Updating HPA ${hpa_name} thresholds"

    if openclaw_kubectl_patch "horizontalpodautoscaler" "$hpa_name" "$patch_json"; then
        openclaw_log_success "HPA ${hpa_name} thresholds updated"
        return 0
    else
        return 1
    fi
}

openclaw_api_update_hpa_replicas() {
    local hpa_name="$1"
    local min_replicas="${2:-}"
    local max_replicas="${3:-}"

    local -a spec_parts=()

    if [[ -n "$min_replicas" ]]; then
        spec_parts+=("\"minReplicas\":${min_replicas}")
    fi

    if [[ -n "$max_replicas" ]]; then
        spec_parts+=("\"maxReplicas\":${max_replicas}")
    fi

    if [[ ${#spec_parts[@]} -eq 0 ]]; then
        openclaw_log_error "No replica count specified (min or max required)"
        return 1
    fi

    local spec_joined
    spec_joined=$(IFS=,; echo "${spec_parts[*]}")
    local patch_json="{\"spec\":{${spec_joined}}}"

    openclaw_log_info "Updating HPA ${hpa_name} replica bounds"

    if openclaw_kubectl_patch "horizontalpodautoscaler" "$hpa_name" "$patch_json"; then
        openclaw_log_success "HPA ${hpa_name} replica bounds updated"
        return 0
    else
        return 1
    fi
}

openclaw_api_get_hpa_current_metrics() {
    local hpa_name="$1"
    local json_file
    json_file=$(openclaw_kubectl_get_json_file "horizontalpodautoscalers" "$hpa_name") || return 1

    local metrics_count
    metrics_count=$(openclaw_process_json_script_file "$json_file" "
import json, sys

input_path = sys.argv[1]
output_path = sys.argv[2]

with open(input_path, 'r') as f:
    data = json.load(f)

metrics = data.get('status', {}).get('currentMetrics', [])

with open(output_path, 'w') as f:
    f.write(str(len(metrics)))
" 30 || echo "0")

    cat "$json_file"
}

openclaw_api_delete_pod() {
    local pod_name="$1"
    local grace_period="${2:-}"

    local -a args=("delete" "pod" "$pod_name")

    if [[ -n "$grace_period" ]]; then
        args+=("--grace-period=${grace_period}")
    fi

    if openclaw_is_dry_run; then
        openclaw_log_info "[DRY-RUN] Would delete pod ${pod_name}"
        return 0
    fi

    if openclaw_kubectl_exec "${args[@]}"; then
        return 0
    else
        return 1
    fi
}

openclaw_api_get_events() {
    local -a extra_args=("$@")
    openclaw_kubectl_get_json "events" "" "${extra_args[@]}"
}

openclaw_api_describe() {
    local resource="$1"
    local name="$2"
    openclaw_kubectl_exec "describe" "$resource" "$name"
    local out_file
    out_file=$(openclaw_kubectl_get_last_output_file)
    if [[ -f "$out_file" ]]; then
        cat "$out_file"
    fi
}

openclaw_api_cordon_node() {
    local node_name="$1"

    openclaw_log_info "Cordoning node: ${node_name}"

    local -a args=("cordon" "$node_name")

    if openclaw_is_dry_run; then
        openclaw_log_info "[DRY-RUN] Would cordon node ${node_name}"
        return 0
    fi

    if openclaw_kubectl_exec "${args[@]}"; then
        openclaw_log_success "Node ${node_name} cordoned successfully"
        return 0
    else
        openclaw_log_error "Failed to cordon node ${node_name}: ${OPENCLAW_KUBECTL_LAST_ERROR}"
        return 1
    fi
}

openclaw_api_uncordon_node() {
    local node_name="$1"

    openclaw_log_info "Uncordoning node: ${node_name}"

    local -a args=("uncordon" "$node_name")

    if openclaw_is_dry_run; then
        openclaw_log_info "[DRY-RUN] Would uncordon node ${node_name}"
        return 0
    fi

    if openclaw_kubectl_exec "${args[@]}"; then
        openclaw_log_success "Node ${node_name} uncordoned successfully"
        return 0
    else
        openclaw_log_error "Failed to uncordon node ${node_name}: ${OPENCLAW_KUBECTL_LAST_ERROR}"
        return 1
    fi
}

openclaw_api_taint_node() {
    local node_name="$1"
    local taint_key="$2"
    local taint_value="$3"
    local taint_effect="$4"

    local taint_spec="${taint_key}=${taint_value}:${taint_effect}"
    openclaw_log_info "Adding taint '${taint_spec}' to node: ${node_name}"

    local -a args=("taint" "nodes" "$node_name" "${taint_spec}")

    if openclaw_is_dry_run; then
        openclaw_log_info "[DRY-RUN] Would add taint ${taint_spec} to node ${node_name}"
        return 0
    fi

    if openclaw_kubectl_exec "${args[@]}"; then
        openclaw_log_success "Taint ${taint_spec} added to node ${node_name}"
        return 0
    else
        openclaw_log_error "Failed to add taint to node ${node_name}: ${OPENCLAW_KUBECTL_LAST_ERROR}"
        return 1
    fi
}

openclaw_api_untaint_node() {
    local node_name="$1"
    local taint_key="$2"
    local taint_effect="$3"

    local taint_spec="${taint_key}:${taint_effect}-"
    openclaw_log_info "Removing taint '${taint_key}:${taint_effect}' from node: ${node_name}"

    local -a args=("taint" "nodes" "$node_name" "${taint_spec}")

    if openclaw_is_dry_run; then
        openclaw_log_info "[DRY-RUN] Would remove taint ${taint_key}:${taint_effect} from node ${node_name}"
        return 0
    fi

    if openclaw_kubectl_exec "${args[@]}"; then
        openclaw_log_success "Taint ${taint_key}:${taint_effect} removed from node ${node_name}"
        return 0
    else
        openclaw_log_error "Failed to remove taint from node ${node_name}: ${OPENCLAW_KUBECTL_LAST_ERROR}"
        return 1
    fi
}

openclaw_api_get_pods_on_node_file() {
    local node_name="$1"
    local namespace="${2:-}"
    local -a extra_args=("--field-selector=spec.nodeName=${node_name}")

    if [[ -n "$namespace" ]]; then
        extra_args+=("--namespace=${namespace}")
    else
        extra_args+=("--all-namespaces")
    fi

    openclaw_kubectl_get_json_file "pods" "" "${extra_args[@]}"
}

openclaw_api_get_statefulsets_file() {
    local namespace="${2:-}"
    local -a extra_args=()

    if [[ -z "$namespace" ]]; then
        extra_args+=("--all-namespaces")
    fi

    openclaw_kubectl_get_json_file "statefulsets" "" "${extra_args[@]}"
}

openclaw_api_get_statefulset_file() {
    local sts_name="$1"
    local namespace="$2"

    openclaw_kubectl_get_json_file "statefulsets" "$sts_name" "--namespace=${namespace}"
}

openclaw_api_evict_pod() {
    local pod_name="$1"
    local namespace="$2"
    local grace_period="${3:-}"

    openclaw_log_info "Evicting pod: ${namespace}/${pod_name}"

    local eviction_json_file
    eviction_json_file=$(openclaw_tmpfile_create "eviction") || return 1

    printf '{
  "apiVersion": "policy/v1",
  "kind": "Eviction",
  "metadata": {
    "name": "%s",
    "namespace": "%s"
  }
}' "$pod_name" "$namespace" > "$eviction_json_file" 2>/dev/null

    local -a args=("create" "--namespace=${namespace}" "-f" "$eviction_json_file")

    if [[ -n "$grace_period" ]]; then
        args+=("--grace-period=${grace_period}")
    fi

    if openclaw_is_dry_run; then
        openclaw_log_info "[DRY-RUN] Would evict pod ${namespace}/${pod_name}"
        return 0
    fi

    if openclaw_kubectl_exec "${args[@]}"; then
        openclaw_log_success "Pod ${namespace}/${pod_name} eviction initiated"
        return 0
    else
        local err_content=""
        if [[ -f "$OPENCLAW_KUBECTL_LAST_ERROR_FILE" ]]; then
            err_content=$(head -c 200 "$OPENCLAW_KUBECTL_LAST_ERROR_FILE" 2>/dev/null || true)
        fi
        if [[ "$err_content" == *"429"* ]] || [[ "$err_content" == *"TooManyRequests"* ]]; then
            openclaw_log_warn "Pod ${namespace}/${pod_name} eviction rate-limited, will retry"
            return 2
        fi
        openclaw_log_error "Failed to evict pod ${namespace}/${pod_name}: ${OPENCLAW_KUBECTL_LAST_ERROR}"
        return 1
    fi
}

openclaw_api_get_node_conditions_file() {
    local node_name="$1"
    openclaw_kubectl_get_json_file "nodes" "$node_name"
}

openclaw_api_get_node_metrics_file() {
    local node_name="$1"

    local -a args=("get" "--raw" "/apis/metrics.k8s.io/v1beta1/nodes/${node_name}")

    if openclaw_kubectl_exec "${args[@]}"; then
        local out_file
        out_file=$(openclaw_kubectl_get_last_output_file)
        if [[ -f "$out_file" ]] && openclaw_is_valid_json_file "$out_file"; then
            echo "$out_file"
            return 0
        fi
    fi

    openclaw_log_debug "Node metrics API not available for ${node_name}"
    return 1
}

openclaw_api_get_node_pressure_status_file() {
    local node_name="$1"
    openclaw_kubectl_get_json_file "nodes" "$node_name"
}

openclaw_api_list_all_nodes_file() {
    openclaw_kubectl_get_json_file "nodes"
}
