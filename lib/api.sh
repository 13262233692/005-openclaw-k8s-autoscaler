#!/bin/bash

# Open Claw - API Layer (Kubectl Wrapper & JSON Parser)
# Low-level communication module: wraps kubectl commands and parses JSON output

OPENCLAW_API_LOADED=1

OPENCLAW_KUBECTL_LAST_OUTPUT=""
OPENCLAW_KUBECTL_LAST_ERROR=""
OPENCLAW_KUBECTL_LAST_EXIT_CODE=0

openclaw_kubectl_build_cmd() {
    local cmd=("$OPENCLAW_KUBECTL_BIN")

    if [[ -n "${OPENCLAW_KUBECONFIG:-}" ]]; then
        cmd+=("--kubeconfig=${OPENCLAW_KUBECONFIG}")
    fi

    if [[ -n "${OPENCLAW_KUBECTL_NAMESPACE:-}" ]]; then
        cmd+=("--namespace=${OPENCLAW_KUBECTL_NAMESPACE}")
    fi

    echo "${cmd[@]}"
}

openclaw_kubectl_exec() {
    local args=("$@")
    local base_cmd
    base_cmd=$(openclaw_kubectl_build_cmd)
    local full_cmd="${base_cmd} ${args[*]}"

    openclaw_log_debug "kubectl exec: ${full_cmd}"

    local output
    local stderr
    local exit_code

    if output=$(eval "$full_cmd" 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi

    OPENCLAW_KUBECTL_LAST_OUTPUT="$output"
    OPENCLAW_KUBECTL_LAST_ERROR=""
    OPENCLAW_KUBECTL_LAST_EXIT_CODE=$exit_code

    if [[ $exit_code -ne 0 ]]; then
        OPENCLAW_KUBECTL_LAST_ERROR="$output"
        openclaw_log_debug "kubectl exit code: ${exit_code}"
        openclaw_log_debug "kubectl stderr: ${output}"
    fi

    return $exit_code
}

openclaw_kubectl_get_json() {
    local resource="$1"
    local name="${2:-}"
    local extra_args=("${@:3}")

    local args=("get" "$resource" "-o" "json")

    if [[ -n "$name" ]]; then
        args+=("$name")
    fi

    args+=("${extra_args[@]}")

    if openclaw_kubectl_exec "${args[@]}"; then
        if openclaw_is_valid_json "$OPENCLAW_KUBECTL_LAST_OUTPUT"; then
            echo "$OPENCLAW_KUBECTL_LAST_OUTPUT"
            return 0
        else
            openclaw_log_error "Invalid JSON output from kubectl"
            return 1
        fi
    else
        return 1
    fi
}

openclaw_kubectl_patch() {
    local resource="$1"
    local name="$2"
    local patch_json="$3"
    local patch_type="${4:-strategic}"

    openclaw_log_debug "Patching ${resource}/${name} with type ${patch_type}"

    local args=("patch" "$resource" "$name" "--type=${patch_type}" "-p" "${patch_json}")

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

openclaw_api_get_node_status() {
    local node_name="$1"
    openclaw_kubectl_get_json "nodes" "$node_name"
}

openclaw_api_get_pods() {
    local selector="${1:-}"
    local extra_args=()

    if [[ -n "$selector" ]]; then
        extra_args+=("--selector=${selector}")
    fi

    openclaw_kubectl_get_json "pods" "" "${extra_args[@]}"
}

openclaw_api_get_pod_status() {
    local pod_name="$1"
    openclaw_kubectl_get_json "pods" "$pod_name"
}

openclaw_api_get_deployments() {
    local selector="${1:-}"
    local extra_args=()

    if [[ -n "$selector" ]]; then
        extra_args+=("--selector=${selector}")
    fi

    openclaw_kubectl_get_json "deployments" "" "${extra_args[@]}"
}

openclaw_api_get_deployment() {
    local deploy_name="$1"
    openclaw_kubectl_get_json "deployments" "$deploy_name"
}

openclaw_api_get_hpa_list() {
    openclaw_kubectl_get_json "horizontalpodautoscalers"
}

openclaw_api_get_hpa() {
    local hpa_name="$1"
    openclaw_kubectl_get_json "horizontalpodautoscalers" "$hpa_name"
}

openclaw_api_get_metrics_pods() {
    local selector="${1:-}"
    local extra_args=()

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
    local deploy_json
    deploy_json=$(openclaw_api_get_deployment "$deploy_name") || return 1
    openclaw_extract_json_field "$deploy_json" ".spec.replicas"
}

openclaw_api_get_deployment_ready_replicas() {
    local deploy_name="$1"
    local deploy_json
    deploy_json=$(openclaw_api_get_deployment "$deploy_name") || return 1
    openclaw_extract_json_field "$deploy_json" ".status.readyReplicas"
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

    local args=("rollout" "restart" "deployment" "$deploy_name")

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

    local args=("rollout" "status" "deployment" "$deploy_name" "--timeout=${timeout}")

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
    local metrics_parts=()

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

    local spec_parts=()

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
    local hpa_json
    hpa_json=$(openclaw_api_get_hpa "$hpa_name") || return 1

    local cpu_current
    local mem_current
    local cpu_target
    local mem_target

    local metrics_count
    metrics_count=$(echo "$hpa_json" | python3 -c "
import json,sys
data = json.load(sys.stdin)
metrics = data.get('status', {}).get('currentMetrics', [])
print(len(metrics))
" 2>/dev/null || echo "0")

    echo "$hpa_json"
}

openclaw_api_delete_pod() {
    local pod_name="$1"
    local grace_period="${2:-}"

    local args=("delete" "pod" "$pod_name")

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
    local extra_args=("$@")
    openclaw_kubectl_get_json "events" "" "${extra_args[@]}"
}

openclaw_api_describe() {
    local resource="$1"
    local name="$2"
    openclaw_kubectl_exec "describe" "$resource" "$name"
    echo "$OPENCLAW_KUBECTL_LAST_OUTPUT"
}
