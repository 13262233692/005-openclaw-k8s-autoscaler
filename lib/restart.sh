#!/bin/bash

# Open Claw - Graceful Restart Module
# Business layer: Container instance graceful restart functionality

OPENCLAW_RESTART_LOADED=1

openclaw_cmd_restart() {
    local target_deployment=""
    local target_selector=""
    local target_all=false
    local grace_period="$OPENCLAW_GRACEFUL_PERIOD"
    local batch_size="$OPENCLAW_RESTART_BATCH_SIZE"
    local interval="$OPENCLAW_RESTART_INTERVAL"
    local auto_rollback=false
    local skip_confirm=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--deployment)
                target_deployment="$2"
                shift 2
                ;;
            -l|--label)
                target_selector="$2"
                shift 2
                ;;
            --all)
                target_all=true
                shift
                ;;
            --grace-period)
                grace_period="$2"
                shift 2
                ;;
            --batch-size)
                batch_size="$2"
                shift 2
                ;;
            --interval)
                interval="$2"
                shift 2
                ;;
            --rollback)
                auto_rollback=true
                shift
                ;;
            -y|--yes)
                skip_confirm=true
                shift
                ;;
            -h|--help)
                openclaw_help_restart
                return 0
                ;;
            -*)
                openclaw_log_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$target_deployment" ]]; then
                    target_deployment="$1"
                else
                    openclaw_log_error "Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if ! openclaw_validate_positive_int "$grace_period"; then
        openclaw_log_error "Invalid grace period: ${grace_period}"
        return 1
    fi

    if ! openclaw_validate_positive_int "$batch_size"; then
        openclaw_log_error "Invalid batch size: ${batch_size}"
        return 1
    fi

    if ! openclaw_validate_positive_int "$interval"; then
        openclaw_log_error "Invalid interval: ${interval}"
        return 1
    fi

    local deployments=()

    if [[ "$target_all" == "true" ]]; then
        openclaw_log_info "Discovering all deployments in namespace: ${OPENCLAW_KUBECTL_NAMESPACE}"
        local depl_json
        depl_json=$(openclaw_api_get_deployments) || {
            openclaw_log_error "Failed to get deployment list"
            return 1
        }
        deployments=($(echo "$depl_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    print(item['metadata']['name'])
" 2>/dev/null))
        if [[ ${#deployments[@]} -eq 0 ]]; then
            openclaw_log_warn "No deployments found in namespace: ${OPENCLAW_KUBECTL_NAMESPACE}"
            return 0
        fi
    elif [[ -n "$target_selector" ]]; then
        openclaw_log_info "Discovering deployments with selector: ${target_selector}"
        local depl_json
        depl_json=$(openclaw_api_get_deployments "$target_selector") || {
            openclaw_log_error "Failed to get deployment list by selector"
            return 1
        }
        deployments=($(echo "$depl_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    print(item['metadata']['name'])
" 2>/dev/null))
        if [[ ${#deployments[@]} -eq 0 ]]; then
            openclaw_log_warn "No deployments found matching selector: ${target_selector}"
            return 0
        fi
    elif [[ -n "$target_deployment" ]]; then
        deployments=("$target_deployment")
    else
        openclaw_log_error "No target specified. Use -d, -l, or --all"
        return 1
    fi

    openclaw_trace_set_context "target_count" "${#deployments[@]}"
    openclaw_trace_set_context "grace_period" "$grace_period"
    openclaw_trace_set_context "batch_size" "$batch_size"

    openclaw_log_info "Found ${#deployments[@]} deployment(s) to restart:"
    for depl in "${deployments[@]}"; do
        openclaw_log_info "  - ${depl}"
    done

    if [[ "$skip_confirm" != "true" ]] && [[ "$target_all" == "true" ]]; then
        if ! openclaw_confirm_action "Restart all ${#deployments[@]} deployment(s)?" "n"; then
            openclaw_log_info "Operation cancelled by user"
            return 0
        fi
    fi

    local failed_deployments=()
    local success_deployments=()
    local total_count=${#deployments[@]}
    local current_index=0

    for depl in "${deployments[@]}"; do
        current_index=$((current_index + 1))
        openclaw_log_info "[$current_index/$total_count] Processing deployment: ${depl}"

        openclaw_trace_add_step "restart_${depl}" "restart_deployment" "Restarting deployment ${depl}"

        if openclaw_restart_deployment_graceful "$depl" "$grace_period"; then
            success_deployments+=("$depl")
            openclaw_trace_update_step "restart_${depl}" "success" ""
            openclaw_log_success "Deployment ${depl} restart completed successfully"
        else
            failed_deployments+=("$depl")
            openclaw_trace_update_step "restart_${depl}" "failed" "Restart failed"
            openclaw_log_error "Deployment ${depl} restart failed"

            if [[ "$auto_rollback" == "true" ]]; then
                openclaw_log_warn "Auto rollback initiated for ${depl}"
                openclaw_rollback_deployment "$depl"
            fi
        fi

        if [[ $current_index -lt $total_count ]]; then
            openclaw_log_debug "Waiting ${interval}s before next deployment..."
            sleep "$interval"
        fi
    done

    openclaw_log_info ""
    openclaw_log_info "=== Restart Summary ==="
    openclaw_log_info "Total: ${total_count}"
    openclaw_log_success "Successful: ${#success_deployments[@]}"
    if [[ ${#failed_deployments[@]} -gt 0 ]]; then
        openclaw_log_error "Failed: ${#failed_deployments[@]}"
        for f in "${failed_deployments[@]}"; do
            openclaw_log_error "  - ${f}"
        done
    fi

    openclaw_trace_set_result "total_count" "$total_count"
    openclaw_trace_set_result "success_count" "${#success_deployments[@]}"
    openclaw_trace_set_result "failed_count" "${#failed_deployments[@]}"

    if [[ ${#failed_deployments[@]} -gt 0 ]]; then
        return 1
    fi

    return 0
}

openclaw_restart_deployment_graceful() {
    local deploy_name="$1"
    local grace_period="$2"

    openclaw_log_debug "Starting graceful restart for: ${deploy_name}"

    local pre_replicas
    pre_replicas=$(openclaw_api_get_deployment_replicas "$deploy_name")
    if [[ -z "$pre_replicas" || "$pre_replicas" == "null" ]]; then
        openclaw_log_error "Failed to get replica count for ${deploy_name}"
        return 1
    fi

    openclaw_trace_set_context "pre_replicas" "$pre_replicas"
    openclaw_log_info "  Pre-restart replicas: ${pre_replicas}"

    openclaw_trace_add_step "verify_${deploy_name}" "verify_deployment" "Verifying deployment exists"

    local depl_json
    depl_json=$(openclaw_api_get_deployment "$deploy_name") || {
        openclaw_trace_update_step "verify_${deploy_name}" "failed" "Deployment not found"
        openclaw_log_error "  Deployment ${deploy_name} not found"
        return 1
    }
    openclaw_trace_update_step "verify_${deploy_name}" "success" "Deployment exists"

    openclaw_trace_add_step "init_restart_${deploy_name}" "initiate_restart" "Initiating rollout restart"

    if ! openclaw_api_restart_deployment "$deploy_name" "$grace_period"; then
        openclaw_trace_update_step "init_restart_${deploy_name}" "failed" "Failed to initiate restart"
        return 1
    fi
    openclaw_trace_update_step "init_restart_${deploy_name}" "success" "Restart initiated"

    openclaw_trace_add_step "wait_rollout_${deploy_name}" "wait_rollout" "Waiting for rollout completion"

    local timeout="300s"
    if ! openclaw_api_deployment_rollout_status "$deploy_name" "$timeout"; then
        openclaw_trace_update_step "wait_rollout_${deploy_name}" "failed" "Rollout timed out or failed"
        openclaw_log_error "  Rollout did not complete within timeout"
        return 1
    fi
    openclaw_trace_update_step "wait_rollout_${deploy_name}" "success" "Rollout completed"

    openclaw_trace_add_step "verify_post_${deploy_name}" "verify_post" "Verifying post-restart state"

    local post_replicas
    post_replicas=$(openclaw_api_get_deployment_ready_replicas "$deploy_name")
    openclaw_trace_set_context "post_replicas" "$post_replicas"

    if [[ -z "$post_replicas" || "$post_replicas" == "null" ]]; then
        openclaw_trace_update_step "verify_post_${deploy_name}" "failed" "Could not verify post-restart state"
        openclaw_log_warn "  Could not verify post-restart replica count"
    else
        openclaw_log_info "  Post-restart ready replicas: ${post_replicas}"
        openclaw_trace_update_step "verify_post_${deploy_name}" "success" "Post-restart verified"
    fi

    openclaw_audit_event "restart" "deployment" "$deploy_name" "completed" \
        "grace_period=${grace_period}" "pre_replicas=${pre_replicas}" "post_replicas=${post_replicas}"

    return 0
}

openclaw_rollback_deployment() {
    local deploy_name="$1"

    openclaw_log_info "Rolling back deployment: ${deploy_name}"

    if openclaw_is_dry_run; then
        openclaw_log_info "[DRY-RUN] Would rollback deployment ${deploy_name}"
        return 0
    fi

    if openclaw_kubectl_exec "rollout" "undo" "deployment" "$deploy_name"; then
        openclaw_log_success "Deployment ${deploy_name} rollback initiated"
        openclaw_audit_event "rollback" "deployment" "$deploy_name" "completed"
        return 0
    else
        openclaw_log_error "Failed to rollback deployment ${deploy_name}: ${OPENCLAW_KUBECTL_LAST_ERROR}"
        openclaw_audit_event "rollback" "deployment" "$deploy_name" "failed"
        return 1
    fi
}
