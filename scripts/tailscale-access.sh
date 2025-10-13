#!/usr/bin/env bash
# Tailscale Remote Access Helper

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

check_tailscale() {
    if ! command -v tailscale &> /dev/null; then
        log_error "Tailscale is not installed"
        echo ""
        echo "Install with:"
        echo "  brew install tailscale"
        echo ""
        exit 1
    fi
    log_success "Tailscale is installed"
}

check_tailscale_running() {
    if ! tailscale status &> /dev/null; then
        log_warning "Tailscale is not running"
        echo ""
        echo "Start Tailscale with:"
        echo "  sudo tailscale up"
        echo ""
        read -p "Do you want to start it now? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo tailscale up
            log_success "Tailscale started"
        else
            exit 1
        fi
    fi
    log_success "Tailscale is running"
}

show_status() {
    log_info "Tailscale network status:"
    echo ""
    tailscale status
    echo ""

    if tailscale status | grep -q "tag:k8s"; then
        log_success "Kubernetes cluster found in Tailscale network!"
    else
        log_warning "Kubernetes cluster not found in Tailscale network"
        echo ""
        echo "Make sure:"
        echo "  1. You pushed the Tailscale config to GitHub"
        echo "  2. Flux deployed it to the cluster (wait ~5 mins)"
        echo "  3. The Tailscale operator is running in the cluster"
    fi
}

setup_context() {
    log_info "Finding Kubernetes cluster in Tailscale network..."

    # Get the Tailscale IP of the kubernetes operator
    local k8s_ip=$(tailscale status --json | jq -r '.Peer[] | select(.HostName | contains("operator")) | .TailscaleIPs[0]' 2>/dev/null || echo "")

    if [[ -z "$k8s_ip" ]]; then
        log_error "Could not find Kubernetes cluster in Tailscale network"
        echo ""
        echo "Run: $0 status"
        echo ""
        echo "Or manually find the IP with: tailscale status"
        exit 1
    fi

    log_success "Found cluster at: $k8s_ip"

    # Get CA data from existing kubeconfig
    local ca_data=$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="kubernetes")].cluster.certificate-authority-data}' 2>/dev/null || echo "")

    if [[ -z "$ca_data" ]]; then
        log_error "Could not get CA data from kubeconfig"
        echo ""
        echo "Make sure your local kubeconfig exists and has cluster 'kubernetes'"
        exit 1
    fi

    log_info "Creating Tailscale context in kubeconfig..."

    # Add cluster
    kubectl config set-cluster kubernetes-tailscale \
        --server="https://${k8s_ip}:6443" \
        --certificate-authority-data="$ca_data" \
        --embed-certs=true

    # Add context
    kubectl config set-context tailscale-access \
        --cluster=kubernetes-tailscale \
        --user=admin@kubernetes \
        --namespace=default

    log_success "Context 'tailscale-access' created!"
    echo ""
    echo "Test it with:"
    echo "  kubectl --context tailscale-access get nodes"
}

test_connection() {
    log_info "Testing connection to cluster via Tailscale..."
    echo ""

    if kubectl --context tailscale-access get nodes --request-timeout=10s 2>/dev/null; then
        log_success "Connection successful!"
        echo ""
        echo "You can now use:"
        echo "  kubectl --context tailscale-access get pods -A"
        echo "  flux --context tailscale-access get all"
        echo ""
        echo "Or switch to Tailscale permanently:"
        echo "  kubectl config use-context tailscale-access"
    else
        log_error "Connection failed"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check Tailscale status: $0 status"
        echo "  2. Ping the cluster: tailscale status"
        echo "  3. Check if operator is deployed in cluster"
    fi
}

show_help() {
    cat << EOF
${GREEN}Tailscale Remote Access Helper${NC}

Manages Tailscale connection for remote Kubernetes access.

${YELLOW}Usage:${NC}
  $0 [command]

${YELLOW}Commands:${NC}
  ${GREEN}status${NC}        Show Tailscale network status
  ${GREEN}setup${NC}         Set up kubeconfig context for Tailscale
  ${GREEN}test${NC}          Test connection to cluster
  ${GREEN}switch${NC}        Switch to Tailscale context
  ${GREEN}help${NC}          Show this help

${YELLOW}Examples:${NC}
  # Initial setup
  $0 status                    # Check if cluster is visible
  $0 setup                     # Create kubeconfig context
  $0 test                      # Test connection

  # Daily usage
  $0 switch                    # Switch to Tailscale
  kubectl get nodes            # Use cluster remotely!

${YELLOW}Requirements:${NC}
  - Tailscale installed (brew install tailscale)
  - Tailscale running (sudo tailscale up)
  - Tailscale operator deployed in cluster

${YELLOW}Documentation:${NC}
  See: docs/TAILSCALE-SETUP.md

EOF
}

switch_context() {
    kubectl config use-context tailscale-access
    log_success "Switched to Tailscale context"
    echo ""
    echo "All kubectl commands now use Tailscale!"
    echo ""
    kubectl cluster-info
}

main() {
    local command="${1:-help}"

    case "$command" in
        status)
            check_tailscale
            check_tailscale_running
            show_status
            ;;
        setup)
            check_tailscale
            check_tailscale_running
            setup_context
            ;;
        test)
            check_tailscale
            check_tailscale_running
            test_connection
            ;;
        switch)
            switch_context
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
