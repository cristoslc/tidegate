#!/bin/sh
# tidegate vm — Launch an agent VM with libkrun + gvproxy + virtiofs.
#
# Boots a libkrun microVM with virtio-net networking (via gvproxy)
# and virtiofs workspace mounting. All traffic is routed through
# the Tidegate gateway and egress proxy.
#
# Usage:
#   tidegate-vm.sh start [options]      Boot a VM
#   tidegate-vm.sh check-deps           Verify dependencies
#   tidegate-vm.sh --help               Show usage
#
# Options:
#   --image <ref>          OCI image (default: tidegate-agent:latest)
#   --workspace <path>     Host workspace path (default: .)
#   --gateway <host:port>  Gateway address (default: localhost:4100)
#   --proxy <host:port>    Proxy address (default: localhost:3128)
#   --cpus <n>             vCPU count (default: 4)
#   --memory <mb>          RAM in MB (default: 4096)
#   --dry-run              Print config without starting VM

set -e

# Defaults
IMAGE="tidegate-agent:latest"
WORKSPACE="$(pwd)"
GATEWAY_HOST="localhost"
GATEWAY_PORT="4100"
PROXY_HOST="localhost"
PROXY_PORT="3128"
CPUS=4
MEMORY=4096
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage: tidegate-vm.sh <command> [options]

Commands:
  start        Boot a VM with the configured settings
  check-deps   Verify required dependencies are installed

Options:
  --image <ref>          OCI image reference (default: tidegate-agent:latest)
  --workspace <path>     Host directory to mount via virtiofs (default: .)
  --gateway <host:port>  Tidegate gateway address (default: localhost:4100)
  --proxy <host:port>    Egress proxy address (default: localhost:3128)
  --cpus <n>             Number of vCPUs (default: 4)
  --memory <mb>          RAM in megabytes (default: 4096)
  --dry-run              Print resolved config without starting the VM
  --help                 Show this help
EOF
}

parse_host_port() {
    # Split host:port, defaulting to localhost if no host given
    input="$1"
    case "$input" in
        *:*) printf '%s' "$input" ;;
        *)   printf 'localhost:%s' "$input" ;;
    esac
}

check_deps() {
    missing=""
    if ! command -v krunkit >/dev/null 2>&1; then
        missing="$missing krunkit"
    fi
    if ! command -v gvproxy >/dev/null 2>&1; then
        missing="$missing gvproxy"
    fi
    if [ "$(uname)" = "Darwin" ] && ! command -v sandbox-exec >/dev/null 2>&1; then
        missing="$missing sandbox-exec"
    fi

    if [ -n "$missing" ]; then
        echo "Missing dependencies:$missing" >&2
        echo "" >&2
        echo "Install with:" >&2
        echo "  brew install krunkit gvproxy    # macOS (Homebrew)" >&2
        return 1
    fi

    echo "All dependencies found: krunkit, gvproxy, sandbox-exec"
    return 0
}

# Parse command
COMMAND=""
case "${1:-}" in
    start)     COMMAND="start"; shift ;;
    check-deps) check_deps; exit $? ;;
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=true; shift
        case "${1:-}" in
            start) COMMAND="start"; shift ;;
            *) COMMAND="start" ;;
        esac ;;
    "") usage; exit 1 ;;
    *) echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        --image)     IMAGE="$2"; shift 2 ;;
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --gateway)
            gw="$(parse_host_port "$2")"
            GATEWAY_HOST="${gw%%:*}"
            GATEWAY_PORT="${gw##*:}"
            shift 2 ;;
        --proxy)
            px="$(parse_host_port "$2")"
            PROXY_HOST="${px%%:*}"
            PROXY_PORT="${px##*:}"
            shift 2 ;;
        --cpus)   CPUS="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

print_config() {
    cat <<EOF
VM Configuration:
  image: $IMAGE
  workspace: $WORKSPACE
  gateway: $GATEWAY_HOST:$GATEWAY_PORT
  proxy: $PROXY_HOST:$PROXY_PORT
  cpus: $CPUS
  memory: $MEMORY
EOF
}

start_vm() {
    if ! check_deps >/dev/null 2>&1; then
        check_deps
        exit 1
    fi

    print_config

    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo "(dry-run mode — VM not started)"
        return 0
    fi

    # Generate Seatbelt profile for gvproxy
    SB_PROFILE="$(mktemp /tmp/gvproxy-egress.XXXXXX.sb)"
    sh "$SCRIPT_DIR/generate-seatbelt-profile.sh" "$GATEWAY_PORT" "$PROXY_PORT" "$SB_PROFILE"

    # gvproxy socket paths
    GVPROXY_SOCK="$(mktemp -u /tmp/gvproxy.XXXXXX.sock)"
    GVPROXY_LISTEN="$(mktemp -u /tmp/gvproxy-listen.XXXXXX.sock)"

    cleanup_vm() {
        [ -n "$GVPROXY_PID" ] && kill "$GVPROXY_PID" 2>/dev/null || true
        rm -f "$SB_PROFILE" "$GVPROXY_SOCK" "$GVPROXY_LISTEN"
    }
    trap cleanup_vm EXIT

    # Start gvproxy under Seatbelt sandbox
    echo "Starting gvproxy (sandboxed)..."
    sandbox-exec -f "$SB_PROFILE" \
        gvproxy \
        -listen "unix://$GVPROXY_LISTEN" \
        -listen-qemu "unix://$GVPROXY_SOCK" \
        -mtu 1500 &
    GVPROXY_PID=$!
    sleep 0.5

    if ! kill -0 "$GVPROXY_PID" 2>/dev/null; then
        echo "Error: gvproxy failed to start" >&2
        exit 1
    fi

    # Start krunkit with virtio-net + virtiofs
    echo "Starting VM via krunkit..."
    krunkit \
        --cpus "$CPUS" \
        --memory "$MEMORY" \
        --virtiofs "$WORKSPACE:/workspace" \
        --net "unixgram://$GVPROXY_SOCK" \
        --restful-uri "tcp://127.0.0.1:0" \
        -- \
        sh -c "
            # Configure networking
            ip addr add 192.168.127.2/24 dev eth0
            ip link set eth0 up
            ip route add default via 192.168.127.1

            # Inject hosts
            echo '$GATEWAY_HOST gateway' >> /etc/hosts
            echo '$PROXY_HOST egress-proxy' >> /etc/hosts

            # Set proxy env
            export HTTP_PROXY=http://$PROXY_HOST:$PROXY_PORT
            export HTTPS_PROXY=http://$PROXY_HOST:$PROXY_PORT
            export TIDEGATE_GATEWAY=http://$GATEWAY_HOST:$GATEWAY_PORT

            echo 'VM ready. Gateway: $GATEWAY_HOST:$GATEWAY_PORT'
            exec sh
        "
}

case "$COMMAND" in
    start) start_vm ;;
    *) usage; exit 1 ;;
esac
