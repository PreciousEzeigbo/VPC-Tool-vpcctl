#!/bin/bash
# vpcctl - Build Your Own Virtual Private Cloud on Linux
# Simple VPC simulator using Linux namespaces, bridge, veth and iptables
# Usage: sudo ./vpcctl <command> [...]
# Commands: create, delete, add-subnet, peer, firewall, list, show, cleanup

set -euo pipefail

# --- Configuration ---
STATE_DIR="/var/run/vpcctl"
LOG_FILE="/var/log/vpcctl.log"
# Auto-detect the internet interface
INTERNET_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
INTERNET_INTERFACE="${INTERNET_INTERFACE:-eth0}"  # Fallback to eth0 if detection fails

# --- Logging and Utilities ---
LOG() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
    echo "[vpcctl] $*"
}

DIE() { 
    LOG "ERROR: $*"
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        DIE "This script must be run as root (sudo)."
    fi
}

validate_cidr() {
    local cidr=$1
    if ! [[ $cidr =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        DIE "Invalid CIDR format: $cidr"
    fi
}

# --- State Management ---
init_state_dir() {
    mkdir -p "$STATE_DIR"
    mkdir -p "$STATE_DIR/vpcs"
    mkdir -p "$STATE_DIR/subnets"
    mkdir -p "$STATE_DIR/peerings"
}

vpc_exists() {
    local vpc_name=$1
    [ -f "$STATE_DIR/vpcs/${vpc_name}.conf" ]
}

subnet_exists() {
    local vpc_name=$1
    local subnet_name=$2
    [ -f "$STATE_DIR/subnets/${vpc_name}-${subnet_name}.conf" ]
}

# --- Network Primitives ---
create_network_namespace() {
    local ns=$1
    if ! ip netns list | grep -q "$ns"; then
        ip netns add "$ns"
        # Enable loopback in namespace
        ip netns exec "$ns" ip link set lo up
        LOG "Created network namespace: $ns"
    fi
}

delete_network_namespace() {
    local ns=$1
    if ip netns list | grep -q "$ns"; then
        ip netns delete "$ns"
        LOG "Deleted network namespace: $ns"
    fi
}

create_bridge() {
    local bridge=$1
    if ! ip link show "$bridge" &>/dev/null; then
        ip link add name "$bridge" type bridge
        ip link set "$bridge" up
        # Disable STP to simplify setup
        echo 0 > "/sys/class/net/$bridge/bridge/stp_state"
        # Enable proxy ARP on bridge to allow communication between different subnets
        echo 1 > "/proc/sys/net/ipv4/conf/$bridge/proxy_arp" 2>/dev/null || true
        LOG "Created bridge: $bridge"
    fi
}

delete_bridge() {
    local bridge=$1
    if ip link show "$bridge" &>/dev/null; then
        ip link set "$bridge" down
        ip link delete "$bridge" type bridge
        LOG "Deleted bridge: $bridge"
    fi
}

create_veth_pair() {
    local veth1=$1 veth2=$2
    if ! ip link show "$veth1" &>/dev/null; then
        ip link add name "$veth1" type veth peer name "$veth2" || DIE "Failed to create veth pair: $veth1 <-> $veth2"
        ip link set "$veth1" up || DIE "Failed to bring up $veth1"
        ip link set "$veth2" up || DIE "Failed to bring up $veth2"
        # Small delay to ensure interfaces are ready
        sleep 0.1
        LOG "Created veth pair: $veth1 <-> $veth2"
    fi
}

delete_veth_pair() {
    local veth=$1
    if ip link show "$veth" &>/dev/null; then
        ip link delete "$veth"
        LOG "Deleted veth: $veth"
    fi
}

# --- Core VPC Operations ---
cmd_create() {
    local vpc_name=$1
    local cidr_block=$2
    
    require_root
    init_state_dir
    validate_cidr "$cidr_block"
    
    if vpc_exists "$vpc_name"; then
        DIE "VPC '$vpc_name' already exists"
    fi
    
    LOG "Creating VPC: $vpc_name with CIDR: $cidr_block"
    
    # Create bridge for VPC
    local bridge_name="br-${vpc_name}"
    create_bridge "$bridge_name"
    
    # Assign IP to bridge (first IP in CIDR with the full CIDR mask)
    local bridge_ip=$(echo "$cidr_block" | sed 's/\.0\//.1\//')
    ip addr add "$bridge_ip" dev "$bridge_name"
    
    # Store bridge IP without CIDR for routing purposes
    local bridge_ip_no_mask=$(echo "$bridge_ip" | cut -d'/' -f1)
    
    # Enable IP forwarding globally
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # Disable bridge netfilter to prevent iptables from filtering bridge traffic
    sysctl -w net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
    sysctl -w net.bridge.bridge-nf-call-ip6tables=0 2>/dev/null || true
    
    # Allow forwarding within the same bridge (same VPC)
    iptables -A FORWARD -i "$bridge_name" -o "$bridge_name" -j ACCEPT 2>/dev/null || true
    
    # Block traffic from this VPC to other VPCs by default (isolation)
    # This will be overridden by peering rules
    for other_vpc_file in "$STATE_DIR/vpcs/"*.conf; do
        if [ -f "$other_vpc_file" ]; then
            source "$other_vpc_file"
            if [ "$BRIDGE" != "$bridge_name" ]; then
                # Block traffic between different VPC bridges
                iptables -I FORWARD -i "$bridge_name" -o "$BRIDGE" -j DROP 2>/dev/null || true
                iptables -I FORWARD -i "$BRIDGE" -o "$bridge_name" -j DROP 2>/dev/null || true
            fi
        fi
    done
    
    # Save VPC configuration
    cat > "$STATE_DIR/vpcs/${vpc_name}.conf" << EOF
VPC_NAME="$vpc_name"
CIDR_BLOCK="$cidr_block"
BRIDGE="$bridge_name"
BRIDGE_IP="$bridge_ip_no_mask"
CREATED_AT="$(date -Iseconds)"
EOF
    
    LOG "VPC '$vpc_name' created successfully (Bridge: $bridge_name, IP: $bridge_ip)"
}

cmd_delete() {
    local vpc_name=$1
    
    require_root
    
    if ! vpc_exists "$vpc_name"; then
        DIE "VPC '$vpc_name' does not exist"
    fi
    
    LOG "Deleting VPC: $vpc_name"
    
    # Load VPC config
    source "$STATE_DIR/vpcs/${vpc_name}.conf"
    
    # Delete all subnets in this VPC
    for subnet_file in "$STATE_DIR/subnets/${vpc_name}"-*.conf; do
        if [ -f "$subnet_file" ]; then
            source "$subnet_file"
            delete_network_namespace "$NAMESPACE"
            delete_veth_pair "$VETH_BR"
            # Clean up DNS config for namespace
            rm -rf "/etc/netns/$NAMESPACE" 2>/dev/null || true
            rm -f "$subnet_file"
            LOG "Deleted subnet: $SUBNET_NAME"
        fi
    done
    
    # Delete peering connections
    for peering_file in "$STATE_DIR/peerings/"*"${vpc_name}"*.conf; do
        if [ -f "$peering_file" ]; then
            source "$peering_file"
            delete_veth_pair "$VETH1"
            delete_veth_pair "$VETH2"
            # Remove peering FORWARD rules if bridges are defined
            if [ -n "$BRIDGE1" ] && [ -n "$BRIDGE2" ]; then
                iptables -D FORWARD -i "$BRIDGE1" -o "$BRIDGE2" -j ACCEPT 2>/dev/null || true
                iptables -D FORWARD -i "$BRIDGE2" -o "$BRIDGE1" -j ACCEPT 2>/dev/null || true
            fi
            rm -f "$peering_file"
            LOG "Deleted peering: $PEERING_NAME"
        fi
    done
    
    # Delete bridge
    delete_bridge "$BRIDGE"
    
    # Remove VPC config
    rm -f "$STATE_DIR/vpcs/${vpc_name}.conf"
    
    LOG "VPC '$vpc_name' deleted successfully"
}

cmd_add_subnet() {
    local vpc_name=$1
    local subnet_name=$2
    local subnet_cidr=$3
    local subnet_type=$4
    
    require_root
    validate_cidr "$subnet_cidr"
    
    if ! vpc_exists "$vpc_name"; then
        DIE "VPC '$vpc_name' does not exist"
    fi
    
    if subnet_exists "$vpc_name" "$subnet_name"; then
        DIE "Subnet '$subnet_name' already exists in VPC '$vpc_name'"
    fi
    
    if [ "$subnet_type" != "public" ] && [ "$subnet_type" != "private" ]; then
        DIE "Subnet type must be 'public' or 'private'"
    fi
    
    LOG "Adding $subnet_type subnet '$subnet_name' to VPC '$vpc_name' with CIDR: $subnet_cidr"
    
    # Load VPC config
    source "$STATE_DIR/vpcs/${vpc_name}.conf"
    
    # Create network namespace for subnet
    local ns_name="ns-${vpc_name}-${subnet_name}"
    create_network_namespace "$ns_name"
    

    # Generate a short hash from vpc and subnet names
    local short_hash=$(echo -n "${vpc_name}-${subnet_name}" | md5sum | cut -c1-6)
    local veth_br="vb-${short_hash}"
    local veth_ns="vn-${short_hash}"
    create_veth_pair "$veth_br" "$veth_ns"
    
    # Connect veth to bridge and namespace
    ip link set "$veth_br" master "$BRIDGE"
    ip link set "$veth_ns" netns "$ns_name"
    
    # Configure namespace networking
    local subnet_prefix=$(echo "$subnet_cidr" | cut -d'/' -f2)
    local ns_ip=$(echo "$subnet_cidr" | sed "s/0\/${subnet_prefix}/2\/${subnet_prefix}/")
    
    # Add bridge IP for this subnet (first IP in subnet CIDR)
    local subnet_gateway=$(echo "$subnet_cidr" | sed "s/0\/${subnet_prefix}/1\/${subnet_prefix}/")
    ip addr add "$subnet_gateway" dev "$BRIDGE" 2>/dev/null || true
    local gateway_ip=$(echo "$subnet_gateway" | cut -d'/' -f1)
    
    ip netns exec "$ns_name" ip addr add "$ns_ip" dev "$veth_ns"
    ip netns exec "$ns_name" ip link set "$veth_ns" name "eth0"
    ip netns exec "$ns_name" ip link set "eth0" up
    
    # Configure DNS in namespace (copy from host)
    mkdir -p /etc/netns/"$ns_name"
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf /etc/netns/"$ns_name"/resolv.conf
    else
        # Fallback to Google DNS
        echo "nameserver 8.8.8.8" > /etc/netns/"$ns_name"/resolv.conf
        echo "nameserver 8.8.4.4" >> /etc/netns/"$ns_name"/resolv.conf
    fi
    
    # Add default route through the bridge gateway (use subnet-specific gateway)
    ip netns exec "$ns_name" ip route add default via "$gateway_ip" dev eth0
    
    # Setup NAT for public subnets
    if [ "$subnet_type" = "public" ]; then
        # Disable bridge netfilter if not already done
        sysctl -w net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
        sysctl -w net.bridge.bridge-nf-call-ip6tables=0 2>/dev/null || true
        
        # Don't NAT traffic staying within the VPC (internal traffic)
        iptables -t nat -I POSTROUTING -s "$CIDR_BLOCK" -d "$CIDR_BLOCK" -j RETURN 2>/dev/null || true
        
        # NAT only traffic going to the internet
        iptables -t nat -A POSTROUTING -s "$subnet_cidr" -o "$INTERNET_INTERFACE" -j MASQUERADE
        
        # Allow forwarding from VPC bridge to internet
        iptables -I FORWARD -i "$BRIDGE" -o "$INTERNET_INTERFACE" -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD -i "$INTERNET_INTERFACE" -o "$BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        
        LOG "Configured NAT for public subnet $subnet_cidr"
    else
        # For private subnets, block direct access from host
        # Block INPUT to the bridge IP for this subnet
        iptables -I INPUT -d "$gateway_ip" -j DROP 2>/dev/null || true
        # Block FORWARD from host to private subnet
        iptables -I FORWARD ! -i "$BRIDGE" -o "$BRIDGE" -d "$subnet_cidr" -j DROP 2>/dev/null || true
        
        LOG "Configured isolation for private subnet $subnet_cidr"
    fi
    
    # Save subnet configuration
    cat > "$STATE_DIR/subnets/${vpc_name}-${subnet_name}.conf" << EOF
SUBNET_NAME="$subnet_name"
SUBNET_CIDR="$subnet_cidr"
SUBNET_TYPE="$subnet_type"
NAMESPACE="$ns_name"
VETH_BR="$veth_br"
VETH_NS="$veth_ns"
NS_IP="$ns_ip"
VPC_NAME="$vpc_name"
EOF
    
    LOG "Subnet '$subnet_name' ($subnet_type) added successfully (Namespace: $ns_name, IP: $ns_ip)"
}

cmd_peer() {
    local vpc1=$1 vpc2=$2
    
    require_root
    
    if ! vpc_exists "$vpc1"; then
        DIE "VPC '$vpc1' does not exist"
    fi
    
    if ! vpc_exists "$vpc2"; then
        DIE "VPC '$vpc2' does not exist"
    fi
    
    local peering_name="${vpc1}-${vpc2}"
    if [ -f "$STATE_DIR/peerings/${peering_name}.conf" ]; then
        DIE "Peering between '$vpc1' and '$vpc2' already exists"
    fi
    
    LOG "Creating VPC peering: $vpc1 <-> $vpc2"
    
    # Load VPC configurations
    source "$STATE_DIR/vpcs/${vpc1}.conf"
    local bridge1=$BRIDGE cidr1=$CIDR_BLOCK bridge_ip1=$BRIDGE_IP
    
    source "$STATE_DIR/vpcs/${vpc2}.conf"  
    local bridge2=$BRIDGE cidr2=$CIDR_BLOCK bridge_ip2=$BRIDGE_IP
    
    # Create veth pair for peering with shortened names (max 15 chars)
    local peer_hash=$(echo -n "${vpc1}-${vpc2}" | md5sum | cut -c1-6)
    local veth1="vp1-${peer_hash}"
    local veth2="vp2-${peer_hash}"
    create_veth_pair "$veth1" "$veth2"
    
    # Connect veth pairs to respective bridges
    ip link set "$veth1" master "$bridge1"
    ip link set "$veth2" master "$bridge2"
    
    # For peering, we need to route traffic between VPCs through the bridge connections
    # Since the veth pairs connect the bridges, traffic will flow through them
    # We just need to tell each bridge how to reach the other VPC's CIDR
    # Route through the local bridge interface
    ip route add "$cidr2" via "$bridge_ip1" dev "$bridge1" onlink 2>/dev/null || true
    ip route add "$cidr1" via "$bridge_ip2" dev "$bridge2" onlink 2>/dev/null || true
    
    # Remove isolation rules between these two VPCs to allow peering
    iptables -D FORWARD -i "$bridge1" -o "$bridge2" -j DROP 2>/dev/null || true
    iptables -D FORWARD -i "$bridge2" -o "$bridge1" -j DROP 2>/dev/null || true
    
    # Add explicit ACCEPT rules for peered VPCs
    iptables -I FORWARD -i "$bridge1" -o "$bridge2" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD -i "$bridge2" -o "$bridge1" -j ACCEPT 2>/dev/null || true
    
    # Save peering configuration
    cat > "$STATE_DIR/peerings/${peering_name}.conf" << EOF
PEERING_NAME="$peering_name"
VPC1="$vpc1"
VPC2="$vpc2"
VETH1="$veth1"
VETH2="$veth2"
BRIDGE1="$bridge1"
BRIDGE2="$bridge2"
CREATED_AT="$(date -Iseconds)"
EOF
    
    LOG "VPC peering '$peering_name' established successfully"
}

cmd_firewall() {
    local policy_file=$1
    
    require_root
    
    if [ ! -f "$policy_file" ]; then
        DIE "Policy file not found: $policy_file"
    fi
    
    LOG "Applying firewall rules from: $policy_file"
    
    # Parse policy file (simplified JSON parsing)
    local subnet_cidr=$(grep '"subnet"' "$policy_file" | cut -d'"' -f4)
    
    # Find matching subnet across all VPCs
    local found=false
    for subnet_file in "$STATE_DIR/subnets/"*.conf; do
        if [ -f "$subnet_file" ]; then
            source "$subnet_file"
            if [ "$SUBNET_CIDR" = "$subnet_cidr" ]; then
                found=true
                LOG "Applying firewall to namespace: $NAMESPACE"
                
                # Clear existing rules
                ip netns exec "$NAMESPACE" iptables -F
                ip netns exec "$NAMESPACE" iptables -P INPUT DROP
                ip netns exec "$NAMESPACE" iptables -P FORWARD DROP
                ip netns exec "$NAMESPACE" iptables -P OUTPUT ACCEPT
                
                # Allow established connections
                ip netns exec "$NAMESPACE" iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
                ip netns exec "$NAMESPACE" iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
                
                # Apply rules from policy
                while read -r rule; do
                    if [[ $rule == *"port"* ]]; then
                        local port=$(echo "$rule" | grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')
                        local protocol=$(echo "$rule" | grep -o '"protocol"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
                        local action=$(echo "$rule" | grep -o '"action"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
                        
                        if [ -n "$port" ] && [ -n "$protocol" ] && [ -n "$action" ]; then
                            if [ "$action" = "allow" ]; then
                                ip netns exec "$NAMESPACE" iptables -A INPUT -p "$protocol" --dport "$port" -j ACCEPT
                                LOG "  ALLOW $protocol port $port"
                            else
                                ip netns exec "$NAMESPACE" iptables -A INPUT -p "$protocol" --dport "$port" -j DROP
                                LOG "  DENY $protocol port $port"
                            fi
                        fi
                    fi
                done < <(grep -o '{[^}]*}' "$policy_file")
                
                LOG "Firewall rules applied to $NAMESPACE"
                return
            fi
        fi
    done
    
    if [ "$found" = false ]; then
        DIE "No matching subnet found for CIDR: $subnet_cidr"
    fi
}

cmd_list() {
    echo "Virtual Private Clouds (VPCs):"
    echo "=============================="
    
    if [ ! -d "$STATE_DIR/vpcs" ] || [ -z "$(ls -A "$STATE_DIR/vpcs" 2>/dev/null)" ]; then
        echo "No VPCs found"
        return
    fi
    
    for vpc_file in "$STATE_DIR/vpcs"/*.conf; do
        source "$vpc_file"
        echo "VPC: $VPC_NAME"
        echo "  CIDR: $CIDR_BLOCK"
        echo "  Bridge: $BRIDGE ($BRIDGE_IP)"
        echo "  Created: $CREATED_AT"
        
        # List subnets for this VPC
        for subnet_file in "$STATE_DIR/subnets/${VPC_NAME}"-*.conf; do
            if [ -f "$subnet_file" ]; then
                source "$subnet_file"
                echo "  Subnet: $SUBNET_NAME ($SUBNET_TYPE) - $SUBNET_CIDR"
                echo "    Namespace: $NAMESPACE"
                echo "    IP: $NS_IP"
            fi
        done
        echo
    done
}

cmd_show() {
    local vpc_name=$1
    
    if ! vpc_exists "$vpc_name"; then
        DIE "VPC '$vpc_name' does not exist"
    fi
    
    echo "VPC Details: $vpc_name"
    echo "======================"
    
    source "$STATE_DIR/vpcs/${vpc_name}.conf"
    echo "CIDR Block: $CIDR_BLOCK"
    echo "Bridge: $BRIDGE ($BRIDGE_IP)"
    echo "Created: $CREATED_AT"
    echo ""
    
    echo "Subnets:"
    for subnet_file in "$STATE_DIR/subnets/${vpc_name}"-*.conf; do
        if [ -f "$subnet_file" ]; then
            source "$subnet_file"
            echo "  - $SUBNET_NAME ($SUBNET_TYPE)"
            echo "    CIDR: $SUBNET_CIDR"
            echo "    Namespace: $NAMESPACE"
            echo "    IP: $NS_IP"
        fi
    done
    
    echo ""
    echo "Peerings:"
    for peering_file in "$STATE_DIR/peerings/"*"${vpc_name}"*.conf; do
        if [ -f "$peering_file" ]; then
            source "$peering_file"
            echo "  - $PEERING_NAME"
        fi
    done
}

cmd_cleanup() {
    require_root
    
    LOG "Cleaning up all VPC resources..."
    
    # Remove all network namespaces created by vpcctl
    for ns in $(ip netns list | grep -o 'ns-[^ ]*'); do
        delete_network_namespace "$ns"
    done
    
    # Remove all bridges created by vpcctl
    for bridge in $(ip link show | grep -o 'br-[^:]*' | uniq); do
        delete_bridge "$bridge"
    done
    
    # Remove all veth interfaces created by vpcctl
    for veth in $(ip link show | grep -oE 'veth-[^:@]*|vb-[^:@]*|vn-[^:@]*|vp1-[^:@]*|vp2-[^:@]*' | uniq); do
        delete_veth_pair "$veth"
    done
    
    # Clean up iptables rules
    iptables -t nat -F
    iptables -F FORWARD
    
    # Remove DNS namespace configs
    rm -rf /etc/netns/ns-* 2>/dev/null || true
    
    # Remove state directory
    rm -rf "$STATE_DIR"
    
    LOG "All VPC resources cleaned up"
}

# --- Main CLI Dispatcher ---
usage() {
    cat << EOF
Usage: $0 <command> [arguments]

Commands:
  create <vpc_name> <cidr>           Create a new VPC
  delete <vpc_name>                  Delete a VPC and all its resources
  add-subnet <vpc> <name> <cidr> <type>  Add subnet to VPC (public/private)
  peer <vpc1> <vpc2>                 Create VPC peering connection
  firewall <policy_file>             Apply firewall rules from JSON policy
  list                               List all VPCs and their subnets
  show <vpc_name>                    Show detailed VPC information
  cleanup                            Remove all VPC resources (full cleanup)

Examples:
  $0 create my-vpc 10.0.0.0/16
  $0 add-subnet my-vpc public 10.0.1.0/24 public
  $0 add-subnet my-vpc private 10.0.2.0/24 private
  $0 peer my-vpc other-vpc
  $0 firewall examples/policy.json
  $0 list
  $0 show my-vpc
  $0 cleanup

EOF
}

main() {
    if [ $# -lt 1 ]; then
        usage
        exit 1
    fi
    
    local command=$1
    shift
    
    case "$command" in
        create)
            if [ $# -ne 2 ]; then
                DIE "Usage: $0 create <vpc_name> <cidr>"
            fi
            cmd_create "$1" "$2"
            ;;
        delete)
            if [ $# -ne 1 ]; then
                DIE "Usage: $0 delete <vpc_name>"
            fi
            cmd_delete "$1"
            ;;
        add-subnet)
            if [ $# -ne 4 ]; then
                DIE "Usage: $0 add-subnet <vpc> <name> <cidr> <type>"
            fi
            cmd_add_subnet "$1" "$2" "$3" "$4"
            ;;
        peer)
            if [ $# -ne 2 ]; then
                DIE "Usage: $0 peer <vpc1> <vpc2>"
            fi
            cmd_peer "$1" "$2"
            ;;
        firewall)
            if [ $# -ne 1 ]; then
                DIE "Usage: $0 firewall <policy_file>"
            fi
            cmd_firewall "$1"
            ;;
        list)
            cmd_list
            ;;
        show)
            if [ $# -ne 1 ]; then
                DIE "Usage: $0 show <vpc_name>"
            fi
            cmd_show "$1"
            ;;
        cleanup)
            cmd_cleanup
            ;;
        *)
            usage
            DIE "Unknown command: $command"
            ;;
    esac
}

# Run main function with all arguments
main "$@"