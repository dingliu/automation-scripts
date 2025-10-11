#!/bin/bash
# ============================================================
# Script Name: set-staticip.sh
# Description: This script configures a static IP address on a
#              remote Linux machine using NetworkManager.
#
# Usage:
#   ./set-staticip.sh -p <passphrase> -k <ssh_key_path> -t <target_node> \
#                     -u <username> -a <static_ip> -g <gateway> -d <dns_servers>
#
# Parameters:
#   -p    Passphrase for SSH private key
#   -k    Filepath of SSH private key
#   -t    Target Linux node (hostname or IP)
#   -u    Username to SSH into the target node
#   -a    Static IPv4 address to set (e.g., 192.168.1.100/24)
#   -g    Gateway IP address
#   -d    DNS servers (comma-separated, e.g., 8.8.8.8,8.8.4.4)
#
# Requirements:
#   - NetworkManager must be installed and running on the target node.
#   - SSH access to the target node with the provided key and username.
#   - SSH user must have sudo privileges without password prompt.
# ============================================================

set -euo pipefail  # Exit on error, undefined vars, and pipe failures

# Add logging capability
LOG_FILE="/tmp/set-staticip-$(date +%Y%m%d-%H%M%S).log"
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)


# Default values
PASSPHRASE=""
SSH_KEY=""
TARGET_NODE=""
USERNAME=""
STATIC_IP=""
GATEWAY=""
DNS_SERVERS=""

# Function to display usage
usage() {
    echo "Usage: $0 -p <passphrase> -k <ssh_key_path> -t <target_node> -u <username> -a <static_ip> -g <gateway> -d <dns_servers>"
    echo "Options:"
    echo "  -p    Passphrase for SSH private key"
    echo "  -k    Filepath of SSH private key"
    echo "  -t    Target Linux node (hostname or IP)"
    echo "  -u    Username to SSH into the target node"
    echo "  -a    Static IPv4 address to set (e.g., 192.168.1.100/24)"
    echo "  -g    Gateway IP address"
    echo "  -d    DNS servers (comma-separated, e.g., 8.8.8.8,8.8.4.4)"
    exit 1
}

validate_ip_address() {
    local ip="$1"
    # Remove CIDR notation for validation
    local ip_only="${ip%/*}"
    if [[ $ip_only =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip_only"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]] || [[ $i -lt 0 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

validate_dns_servers() {
    local dns="$1"
    IFS=',' read -ra DNS_ARRAY <<< "$dns"
    for server in "${DNS_ARRAY[@]}"; do
        if ! validate_ip_address "$server/32"; then
            echo "Error: Invalid DNS server IP: $server"
            return 1
        fi
    done
    return 0
}

# Parse command line options
while getopts "p:k:t:u:a:g:d:h" opt; do
    case $opt in
        p) PASSPHRASE="$OPTARG" ;;
        k) SSH_KEY="$OPTARG" ;;
        t) TARGET_NODE="$OPTARG" ;;
        u) USERNAME="$OPTARG" ;;
        a) STATIC_IP="$OPTARG" ;;
        g) GATEWAY="$OPTARG" ;;
        d) DNS_SERVERS="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required parameters
if [ -z "$PASSPHRASE" ] || [ -z "$SSH_KEY" ] || [ -z "$TARGET_NODE" ] || [ -z "$USERNAME" ] || [ -z "$STATIC_IP" ] || [ -z "$GATEWAY" ] || [ -z "$DNS_SERVERS" ]; then
    echo "Error: All parameters are required"
    usage
fi

# Validate SSH key exists
if [ ! -f "$SSH_KEY" ]; then
    echo "Error: SSH key file not found: $SSH_KEY"
    exit 1
fi

# Validate IP address formats
if ! validate_ip_address "$STATIC_IP"; then
    echo "Error: Invalid static IP address format: $STATIC_IP"
    exit 1
fi

if ! validate_ip_address "$GATEWAY/32"; then
    echo "Error: Invalid gateway IP address: $GATEWAY"
    exit 1
fi

if ! validate_dns_servers "$DNS_SERVERS"; then
    exit 1
fi

# Function to add SSH private key to ssh-agent
add_ssh_key() {
    echo "Adding SSH key to ssh-agent..."

    # Initialize variables to avoid unbound variable errors
    SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}"
    AGENT_STARTED="${AGENT_STARTED:-}"

    echo "Check if ssh-agent is already running"
    if [ -z "$SSH_AUTH_SOCK" ]; then
        eval "$(ssh-agent -s)"
        AGENT_STARTED=1
    fi


    echo "Create secure temporary directory"
    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR"' EXIT
    SSH_ASKPASS="$TEMP_DIR/askpass"
    export SSH_ASKPASS
    cat > "$SSH_ASKPASS" << 'EOF'
#!/bin/bash
echo "$SSH_PASSPHRASE"
EOF
    chmod 0700 "$SSH_ASKPASS"

    echo "Export passphrase securely"
    export SSH_PASSPHRASE="$PASSPHRASE"
    # set to "force" makes ssh-add always use SSH_ASKPASS,
    # even with a terminal attached
    SSH_ASKPASS_REQUIRE=force
    export SSH_ASKPASS_REQUIRE
    echo "Set DISPLAY and redirect stdin to disable terminal"
    export DISPLAY=:0

    if ! ssh-add "$SSH_KEY" < /dev/null 2>/dev/null; then
        echo "Error: Failed to add SSH key to agent"
        exit 1
    fi
    echo "Clear passphrase from environment"
    unset SSH_PASSPHRASE
}

check_networkmanager() {
    echo "Checking if NetworkManager is running on $TARGET_NODE..."
    if ssh -o StrictHostKeyChecking=no "$USERNAME@$TARGET_NODE" "systemctl is-active --quiet NetworkManager"; then
        return 0
    else
        return 1
    fi
}

test_ssh_connectivity() {
    echo "Testing SSH connectivity to $TARGET_NODE..."
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$USERNAME@$TARGET_NODE" "echo 'SSH connection successful'" >/dev/null 2>&1; then
        echo "Error: Cannot establish SSH connection to $TARGET_NODE"
        echo "Please verify:"
        echo "  - Target node is reachable"
        echo "  - SSH service is running"
        echo "  - Username and SSH key are correct"
        exit 1
    fi
}

backup_network_config() {
    echo "Creating backup of current network configuration..."
    local backup_file; backup_file="/tmp/network-backup-$(date +%Y%m%d-%H%M%S).txt"
    ssh -o StrictHostKeyChecking=no "$USERNAME@$TARGET_NODE" "
        echo '=== Current IP Configuration ===' > '$backup_file'
        ip addr show >> '$backup_file'
        echo '' >> '$backup_file'
        echo '=== Current Routes ===' >> '$backup_file'
        ip route show >> '$backup_file'
        echo '' >> '$backup_file'
        echo '=== NetworkManager Connections ===' >> '$backup_file'
        nmcli connection show >> '$backup_file'
        echo 'Backup saved to: $backup_file'
    "
}

# Function to configure static IP using nmcli
configure_with_nmcli() {
    echo "Configuring static IP using NetworkManager on $TARGET_NODE..."

    # Get the active connection name
    CONNECTION=$(ssh -o StrictHostKeyChecking=no "$USERNAME@$TARGET_NODE" "nmcli -t -f NAME connection show --active | head -n1")

    if [ -z "$CONNECTION" ]; then
        echo "Error: Could not detect active network connection"
        exit 1
    fi

    echo "Using connection: $CONNECTION"

    # Configure static IP using nmcli
    ssh -o StrictHostKeyChecking=no "$USERNAME@$TARGET_NODE" "sudo nmcli connection modify '$CONNECTION' ipv4.addresses '$STATIC_IP'"
    ssh -o StrictHostKeyChecking=no "$USERNAME@$TARGET_NODE" "sudo nmcli connection modify '$CONNECTION' ipv4.gateway '$GATEWAY'"
    ssh -o StrictHostKeyChecking=no "$USERNAME@$TARGET_NODE" "sudo nmcli connection modify '$CONNECTION' ipv4.dns '$DNS_SERVERS'"
    ssh -o StrictHostKeyChecking=no "$USERNAME@$TARGET_NODE" "sudo nmcli connection modify '$CONNECTION' ipv4.method manual"
    ssh -o StrictHostKeyChecking=no "$USERNAME@$TARGET_NODE" "sudo nmcli connection modify '$CONNECTION' connection.autoconnect yes"

    # Apply the configuration
    ssh -o StrictHostKeyChecking=no "$USERNAME@$TARGET_NODE" "sudo nmcli connection up '$CONNECTION'"

    echo "Static IP configuration completed successfully using NetworkManager!"
    echo "Target: $TARGET_NODE"
    echo "Connection: $CONNECTION"
    echo "IP Address: $STATIC_IP"
    echo "Gateway: $GATEWAY"
    echo "DNS Servers: $DNS_SERVERS"
}

verify_configuration() {
    echo "Verifying network configuration..."
    local new_ip; new_ip="${STATIC_IP%/*}"  # Remove CIDR notation

    # Wait a moment for network to stabilize
    sleep 5

    # Test if we can still connect (IP might have changed)
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$USERNAME@$new_ip" "echo 'Connection verified'" >/dev/null 2>&1; then
        echo "Warning: Cannot connect to new IP address $new_ip"
        echo "Configuration may have been applied but connection lost"
        return 1
    fi

    # Verify the IP was set correctly
    local actual_ip
    actual_ip=$(ssh -o StrictHostKeyChecking=no "$USERNAME@$new_ip" "ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep '$new_ip'" 2>/dev/null)

    if [ "$actual_ip" == "$new_ip" ]; then
        echo "✓ IP configuration verified successfully"
        return 0
    else
        echo "✗ IP verification failed. Expected: $new_ip, Found: $actual_ip"
        return 1
    fi
}

# Set up cleanup trap
cleanup() {
    if [ -n "$AGENT_STARTED" ]; then
        ssh-agent -k >/dev/null 2>&1
    fi
}
trap cleanup EXIT

# Main execution
echo "Log file: $LOG_FILE"
echo "==== Static IP Configuration Script ===="
echo "Target: $TARGET_NODE"
echo "User: $USERNAME"
echo "Static IP: $STATIC_IP"
echo "Gateway: $GATEWAY"
echo "DNS: $DNS_SERVERS"
echo "========================================"

add_ssh_key
test_ssh_connectivity

if check_networkmanager; then
    backup_network_config
    configure_with_nmcli

    if verify_configuration; then
        echo ""
        echo "✓ Static IP configuration completed successfully!"
    else
        echo ""
        echo "✗️ Configuration applied but verification failed"
        echo "  Please check the target system manually"
    fi
else
    echo "Error: NetworkManager service is not running on $TARGET_NODE"
    echo "This script requires NetworkManager to be active"
    exit 1
fi
