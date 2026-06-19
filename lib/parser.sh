#!/bin/bash

# Open Claw - Parser Layer (Command Router & Argument Dispatcher)
# Parameter parsing and command routing distribution

OPENCLAW_PARSER_LOADED=1

declare -A OPENCLAW_COMMANDS
declare -A OPENCLAW_COMMAND_DESCRIPTIONS

OPENCLAW_GLOBAL_OPTIONS=""
OPENCLAW_COMMAND=""
OPENCLAW_COMMAND_ARGS=()

openclaw_parser_init() {
    openclaw_register_command "help" "openclaw_cmd_help" "Display help information"
    openclaw_register_command "version" "openclaw_cmd_version" "Display version information"
    openclaw_register_command "restart" "openclaw_cmd_restart" "Graceful restart of container instances"
    openclaw_register_command "hpa" "openclaw_cmd_hpa" "HPA dynamic configuration management"
    openclaw_register_command "status" "openclaw_cmd_status" "Get cluster real-time metrics and status"
    openclaw_register_command "audit" "openclaw_cmd_audit" "View execution audit records"
}

openclaw_register_command() {
    local cmd_name="$1"
    local cmd_handler="$2"
    local cmd_desc="$3"
    OPENCLAW_COMMANDS["$cmd_name"]="$cmd_handler"
    OPENCLAW_COMMAND_DESCRIPTIONS["$cmd_name"]="$cmd_desc"
}

openclaw_parse_global_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--namespace)
                OPENCLAW_KUBECTL_NAMESPACE="$2"
                export OPENCLAW_KUBECTL_NAMESPACE
                shift 2
                ;;
            --kubeconfig)
                OPENCLAW_KUBECONFIG="$2"
                export OPENCLAW_KUBECONFIG
                shift 2
                ;;
            --webhook-url)
                OPENCLAW_WEBHOOK_URL="$2"
                export OPENCLAW_WEBHOOK_URL
                shift 2
                ;;
            --no-webhook)
                OPENCLAW_WEBHOOK_ENABLED="false"
                export OPENCLAW_WEBHOOK_ENABLED
                shift
                ;;
            --dry-run)
                OPENCLAW_DRY_RUN="true"
                export OPENCLAW_DRY_RUN
                shift
                ;;
            -v|--verbose)
                OPENCLAW_LOG_LEVEL="DEBUG"
                export OPENCLAW_LOG_LEVEL
                shift
                ;;
            -q|--quiet)
                OPENCLAW_LOG_LEVEL="ERROR"
                export OPENCLAW_LOG_LEVEL
                shift
                ;;
            --record-dir)
                OPENCLAW_RECORDS_DIR="$2"
                export OPENCLAW_RECORDS_DIR
                shift 2
                ;;
            -h|--help)
                OPENCLAW_COMMAND="help"
                return 0
                ;;
            --version)
                OPENCLAW_COMMAND="version"
                return 0
                ;;
            -*)
                openclaw_log_error "Unknown global option: $1"
                return 1
                ;;
            *)
                OPENCLAW_COMMAND="$1"
                shift
                OPENCLAW_COMMAND_ARGS=("$@")
                return 0
                ;;
        esac
    done
}

openclaw_dispatch_command() {
    local cmd="$1"
    shift

    if [[ -z "$cmd" ]]; then
        openclaw_cmd_help
        return 0
    fi

    if [[ -n "${OPENCLAW_COMMANDS[$cmd]}" ]]; then
        local handler="${OPENCLAW_COMMANDS[$cmd]}"
        openclaw_trace_start "$cmd" "$@"
        "$handler" "$@"
        local exit_code=$?
        openclaw_trace_end "$exit_code"
        return $exit_code
    else
        openclaw_log_error "Unknown command: $cmd"
        openclaw_log_info "Use 'openclaw help' for available commands."
        return 1
    fi
}

openclaw_cmd_help() {
    local topic="${1:-}"

    if [[ -n "$topic" ]]; then
        case "$topic" in
            restart)
                openclaw_help_restart
                ;;
            hpa)
                openclaw_help_hpa
                ;;
            status)
                openclaw_help_status
                ;;
            audit)
                openclaw_help_audit
                ;;
            *)
                openclaw_log_error "Unknown help topic: $topic"
                return 1
                ;;
        esac
    else
        openclaw_print_main_help
    fi
    return 0
}

openclaw_print_main_help() {
    echo "${OPENCLAW_NAME} v${OPENCLAW_VERSION}"
    echo "Kubernetes test environment automation CLI tool"
    echo ""
    echo "Usage:"
    echo "  openclaw [global-options] <command> [command-options]"
    echo ""
    echo "Global Options:"
    echo "  -n, --namespace <ns>       Kubernetes namespace (default: default)"
    echo "      --kubeconfig <path>    Path to kubeconfig file"
    echo "      --webhook-url <url>    Webhook audit endpoint URL"
    echo "      --no-webhook           Disable webhook audit"
    echo "      --dry-run              Dry run mode, no actual changes"
    echo "  -v, --verbose              Enable verbose debug output"
    echo "  -q, --quiet                Only show error messages"
    echo "      --record-dir <path>    Execution record output directory"
    echo "  -h, --help                 Display this help message"
    echo "      --version              Display version information"
    echo ""
    echo "Available Commands:"
    for cmd in $(echo "${!OPENCLAW_COMMANDS[@]}" | tr ' ' '\n' | sort); do
        printf "  %-20s %s\n" "$cmd" "${OPENCLAW_COMMAND_DESCRIPTIONS[$cmd]}"
    done
    echo ""
    echo "Use 'openclaw help <command>' for detailed help on a specific command."
}

openclaw_help_restart() {
    echo "Command: restart"
    echo "Graceful restart of container instances"
    echo ""
    echo "Usage:"
    echo "  openclaw restart [options] <deployment-name>"
    echo ""
    echo "Options:"
    echo "  -d, --deployment <name>    Target deployment name"
    echo "  -l, --label <selector>     Restart by label selector"
    echo "      --all                  Restart all deployments in namespace"
    echo "      --grace-period <sec>   Graceful shutdown period (default: 30)"
    echo "      --batch-size <num>     Batch restart size (default: 1)"
    echo "      --interval <sec>       Interval between batch restarts (default: 5)"
    echo "      --rollback             Auto rollback on failure"
    echo "  -y, --yes                  Skip confirmation prompt"
    echo ""
    echo "Examples:"
    echo "  openclaw restart my-app"
    echo "  openclaw restart -l app=web --grace-period 60"
    echo "  openclaw restart --all -n production"
}

openclaw_help_hpa() {
    echo "Command: hpa"
    echo "HPA dynamic configuration management"
    echo ""
    echo "Usage:"
    echo "  openclaw hpa <subcommand> [options]"
    echo ""
    echo "Subcommands:"
    echo "  list          List all HPA configurations"
    echo "  get           Get detailed HPA configuration"
    echo "  set-threshold Set CPU/Memory threshold"
    echo "  set-replicas  Set min/max replicas"
    echo "  disable       Disable HPA (set fixed replicas)"
    echo "  enable        Enable HPA"
    echo ""
    echo "Options:"
    echo "  -n, --name <hpa-name>      HPA resource name"
    echo "      --cpu <percent>        CPU utilization threshold (%)"
    echo "      --memory <percent>     Memory utilization threshold (%)"
    echo "      --min-replicas <num>   Minimum number of replicas"
    echo "      --max-replicas <num>   Maximum number of replicas"
    echo "      --replicas <num>       Fixed number of replicas (for disable)"
    echo ""
    echo "Examples:"
    echo "  openclaw hpa list"
    echo "  openclaw hpa set-threshold -n my-hpa --cpu 70 --memory 75"
    echo "  openclaw hpa set-replicas -n my-hpa --min 2 --max 20"
}

openclaw_help_status() {
    echo "Command: status"
    echo "Get cluster real-time metrics and status"
    echo ""
    echo "Usage:"
    echo "  openclaw status [options] [resource-type]"
    echo ""
    echo "Resource Types:"
    echo "  nodes         Node status and resource usage"
    echo "  pods          Pod status and resource usage"
    echo "  deployments   Deployment status"
    echo "  hpa           HPA status and current metrics"
    echo "  all           Show all status information (default)"
    echo ""
    echo "Options:"
    echo "  -o, --output <format>      Output format: table|json|yaml (default: table)"
    echo "  -w, --watch                Watch mode, refresh continuously"
    echo "      --interval <sec>       Watch refresh interval (default: 5)"
    echo ""
    echo "Examples:"
    echo "  openclaw status"
    echo "  openclaw status pods -o json"
    echo "  openclaw status hpa -w"
}

openclaw_help_audit() {
    echo "Command: audit"
    echo "View execution audit records"
    echo ""
    echo "Usage:"
    echo "  openclaw audit [options]"
    echo ""
    echo "Options:"
    echo "  -l, --list                 List recent audit records"
    echo "  -s, --show <id>            Show details of specific record"
    echo "      --limit <num>          Number of records to list (default: 20)"
    echo "      --format <format>      Output format: json|text (default: text)"
    echo "      --since <time>         Show records since specific time"
    echo ""
    echo "Examples:"
    echo "  openclaw audit -l"
    echo "  openclaw audit -s abc123"
    echo "  openclaw audit -l --limit 50 --format json"
}

openclaw_cmd_version() {
    echo "${OPENCLAW_NAME} v${OPENCLAW_VERSION}"
    return 0
}
