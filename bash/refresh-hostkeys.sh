#!/bin/bash
# ============================================================
# Script Name: refresh-hostkeys.sh
# Description: This script refreshes SSH host keys for one or
#              multiple target hosts by removing old keys and
#              scanning for new ones.
#
# Usage:
#   ./refresh-hostkeys.sh -a <host_addresses>
#
# Parameters:
#   -a    Comma-separated IPv4 addresses (e.g., '192.168.1.100' or '192.168.1.100,192.168.1.101')
#
# Examples:
#   ./refresh-hostkeys.sh -a "192.168.1.100"
#   ./refresh-hostkeys.sh -a "192.168.1.100,192.168.1.101"
#   ./refresh-hostkeys.sh -a "192.168.1.100, 192.168.1.101, 192.168.1.102"
#
# Requirements:
#   - ssh-keygen and ssh-keyscan commands available
#   - Network connectivity to target hosts
#   - Write access to ~/.ssh/known_hosts file
# ============================================================

set -euo pipefail  # Exit on error, undefined vars, and pipe failures

# Add logging capability
LOG_FILE="/tmp/refresh-hostkeys-$(date +%Y%m%d-%H%M%S).log"
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# Default values
HOST_ADDRESSES=""

# Function to display usage
usage() {
    echo "Usage: $0 -a <host_addresses>"
    echo "Options:"
    echo "  -a    Comma-separated IPv4 addresses (e.g., '192.168.1.100' or '192.168.1.100,192.168.1.101')"
    echo ""
    echo "Examples:"
    echo "  $0 -a \"192.168.1.100\""
    echo "  $0 -a \"192.168.1.100,192.168.1.101\""
    echo "  $0 -a \"192.168.1.100, 192.168.1.101, 192.168.1.102\""
    exit 1
}

validate_ip_address() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]] || [[ $i -lt 0 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

validate_host_addresses() {
    local addresses="$1"
    # Remove spaces around commas and split by comma
    IFS=',' read -ra ADDR_ARRAY <<< "$addresses"
    for addr in "${ADDR_ARRAY[@]}"; do
        # Trim leading and trailing spaces
        addr=$(echo "$addr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if ! validate_ip_address "$addr"; then
            echo "Error: Invalid IP address format: $addr"
            return 1
        fi
    done
    return 0
}

ensure_ssh_directory() {
    local ssh_dir="$HOME/.ssh"
    local known_hosts_file="$ssh_dir/known_hosts"

    # Create .ssh directory if it doesn't exist
    if [ ! -d "$ssh_dir" ]; then
        echo "Creating SSH directory: $ssh_dir"
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
    fi

    # Create known_hosts file if it doesn't exist
    if [ ! -f "$known_hosts_file" ]; then
        echo "Creating known_hosts file: $known_hosts_file"
        touch "$known_hosts_file"
        chmod 644 "$known_hosts_file"
    fi
}

test_host_connectivity() {
    local host="$1"
    local timeout=5

    echo "Testing connectivity to $host..."

    # Use nc (netcat) to test SSH port connectivity
    if command -v nc >/dev/null 2>&1; then
        if timeout "$timeout" nc -z "$host" 22 >/dev/null 2>&1; then
            echo "[OK] Host $host is reachable on SSH port 22"
            return 0
        else
            echo "[Error] Host $host is not reachable on SSH port 22"
            return 1
        fi
    else
        # Fallback to ping if nc is not available
        if timeout "$timeout" ping -c 1 "$host" >/dev/null 2>&1; then
            echo "[OK] Host $host responds to ping (SSH port status unknown)"
            return 0
        else
            echo "[Error] Host $host does not respond to ping"
            return 1
        fi
    fi
}

remove_host_key() {
    local host="$1"

    echo "Removing existing host key for $host..."

    # ssh-keygen -R will handle the case where the host doesn't exist
    if ssh-keygen -R "$host" >/dev/null 2>&1; then
        echo "[OK] Host key for $host removed successfully"
    else
        echo "[Info] No existing host key found for $host (this is normal)"
    fi
}

scan_host_key() {
    local host="$1"
    local timeout=10

    echo "Scanning host key for $host..."

    # Use timeout to prevent hanging
    if timeout "$timeout" ssh-keyscan -H "$host" >> ~/.ssh/known_hosts 2>/dev/null; then
        echo "[OK] Host key for $host scanned and added successfully"
        return 0
    else
        echo "[Error] Failed to scan host key for $host (host may be unreachable or SSH service unavailable)"
        return 1
    fi
}

refresh_host_key() {
    local host="$1"
    local is_successful=true

    echo ""
    echo "==== Processing host: $host ===="

    # Always try to remove existing key (handles non-existent keys gracefully)
    remove_host_key "$host"

    # Test connectivity before attempting to scan
    if test_host_connectivity "$host"; then
        if ! scan_host_key "$host"; then
            is_successful=false
        fi
    else
        echo "[Warning] Skipping host key scan for unreachable host: $host"
        is_successful=false
    fi

    if $is_successful; then
        echo "[OK] Host key refresh completed successfully for $host"
        return 0
    else
        echo "[Warning] Host key refresh failed for $host"
        return 1
    fi
}

# Parse command line options
while getopts "a:h" opt; do
    case $opt in
        a) HOST_ADDRESSES="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required parameters
if [ -z "$HOST_ADDRESSES" ]; then
    echo "Error: Host addresses parameter (-a) is required"
    usage
fi

# Validate host addresses format
if ! validate_host_addresses "$HOST_ADDRESSES"; then
    exit 1
fi

# Ensure SSH directory and known_hosts file exist
ensure_ssh_directory

# Main execution
echo "Log file: $LOG_FILE"
echo "==== SSH Host Keys Refresh Script ===="
echo "Target hosts: $HOST_ADDRESSES"
echo "Known hosts file: $HOME/.ssh/known_hosts"
echo "========================================"

# Process each host
IFS=',' read -ra ADDR_ARRAY <<< "$HOST_ADDRESSES"
success_count=0
total_count=0

for addr in "${ADDR_ARRAY[@]}"; do
    # Trim leading and trailing spaces
    addr=$(echo "$addr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    total_count=$((total_count + 1))

    if refresh_host_key "$addr"; then
        success_count=$((success_count + 1))
    fi
done

echo ""
echo "========================================"
echo "SSH Host Keys Refresh Summary:"
echo "Total hosts processed: $total_count"
echo "Successfully processed: $success_count"
echo "Failed: $((total_count - success_count))"

if [ $success_count -eq $total_count ]; then
    echo "[OK] All host keys refreshed successfully!"
    exit 0
else
    echo "[Warning] Some host keys could not be refreshed"
    exit 1
fi
