#!/bin/bash
# Comprehensive VPC Testing Script
# Tests all VPC functionality according to project requirements

set -e

echo "============================================"
echo "VPC Testing Suite"
echo "============================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() {
    echo -e "${GREEN}✓ PASS:${NC} $1"
}

fail() {
    echo -e "${RED}✗ FAIL:${NC} $1"
}

info() {
    echo -e "${YELLOW}ℹ INFO:${NC} $1"
}

section() {
    echo ""
    echo "============================================"
    echo "$1"
    echo "============================================"
}

# Cleanup any existing VPCs first
section "0. Initial Cleanup"
info "Cleaning up any existing VPC resources..."
sudo ./vpcctl.sh cleanup
echo ""

# Test 1: Create VPC
section "1. Test: Create VPC"
info "Creating VPC 'my-vpc' with CIDR 10.0.0.0/16"
sudo ./vpcctl.sh create my-vpc 10.0.0.0/16

if ip link show br-my-vpc &>/dev/null; then
    pass "VPC bridge created successfully"
else
    fail "VPC bridge not found"
fi

# Test 2: Add Public Subnet
section "2. Test: Add Public Subnet"
info "Adding public subnet with CIDR 10.0.1.0/24"
sudo ./vpcctl.sh add-subnet my-vpc public 10.0.1.0/24 public

if ip netns list | grep -q "ns-my-vpc-public"; then
    pass "Public subnet namespace created"
else
    fail "Public subnet namespace not found"
fi

# Test 3: Add Private Subnet
section "3. Test: Add Private Subnet"
info "Adding private subnet with CIDR 10.0.2.0/24"
sudo ./vpcctl.sh add-subnet my-vpc private 10.0.2.0/24 private

if ip netns list | grep -q "ns-my-vpc-private"; then
    pass "Private subnet namespace created"
else
    fail "Private subnet namespace not found"
fi

# Test 4: List VPCs
section "4. Test: List VPCs"
info "Listing all VPCs"
sudo ./vpcctl.sh list

# Test 5: Show VPC Details
section "5. Test: Show VPC Details"
info "Showing details for 'my-vpc'"
sudo ./vpcctl.sh show my-vpc

# Test 6: Test Connectivity - Public to Private Subnet
section "6. Test: Communication Between Subnets in Same VPC"
info "Testing connectivity from public to private subnet"

# Start a simple HTTP server in private subnet
info "Starting HTTP server in private subnet (port 8080)..."
sudo ip netns exec ns-my-vpc-private python3 -m http.server 8080 &>/dev/null &
SERVER_PID=$!
sleep 2

# Try to reach it from public subnet
if sudo ip netns exec ns-my-vpc-public curl -s --connect-timeout 5 http://10.0.2.2:8080 &>/dev/null; then
    pass "Communication between subnets in same VPC works"
else
    fail "Cannot communicate between subnets in same VPC"
fi

# Kill the server
sudo kill $SERVER_PID 2>/dev/null || true

# Test 7: Test Outbound Internet Access from Public Subnet
section "7. Test: Outbound Access from Public Subnet"
info "Testing internet access from public subnet"

if sudo ip netns exec ns-my-vpc-public ping -c 2 8.8.8.8 &>/dev/null; then
    pass "Public subnet has outbound internet access"
else
    fail "Public subnet cannot access internet"
fi

# Test 8: Test Outbound Internet Access from Private Subnet (Should fail or be limited)
section "8. Test: Outbound Access from Private Subnet"
info "Testing internet access from private subnet (should be blocked)"

if sudo ip netns exec ns-my-vpc-private ping -c 2 -W 2 8.8.8.8 &>/dev/null; then
    fail "Private subnet should NOT have direct internet access"
else
    pass "Private subnet correctly blocked from internet"
fi

# Test 9: Create Second VPC for Isolation Test
section "9. Test: VPC Isolation - Create Second VPC"
info "Creating second VPC 'other-vpc' with CIDR 172.16.0.0/16"
sudo ./vpcctl.sh create other-vpc 172.16.0.0/16

info "Adding subnet to other-vpc"
sudo ./vpcctl.sh add-subnet other-vpc web 172.16.1.0/24 public

# Test 10: Test VPC Isolation
section "10. Test: Communication Between Different VPCs (Should Fail)"
info "Testing connectivity from my-vpc to other-vpc (should be blocked)"

# Start server in other-vpc
info "Starting HTTP server in other-vpc subnet..."
sudo ip netns exec ns-other-vpc-web python3 -m http.server 8081 &>/dev/null &
SERVER_PID2=$!
sleep 2

# Try to reach from my-vpc (should fail)
if sudo ip netns exec ns-my-vpc-public curl -s --connect-timeout 3 http://172.16.1.2:8081 &>/dev/null; then
    fail "VPCs should be isolated by default"
else
    pass "VPCs are properly isolated"
fi

sudo kill $SERVER_PID2 2>/dev/null || true

# Test 11: VPC Peering
section "11. Test: VPC Peering"
info "Creating peering connection between my-vpc and other-vpc"
sudo ./vpcctl.sh peer my-vpc other-vpc

sleep 2

# Test connectivity after peering
info "Testing connectivity after peering..."
sudo ip netns exec ns-other-vpc-web python3 -m http.server 8081 &>/dev/null &
SERVER_PID2=$!
sleep 2

if sudo ip netns exec ns-my-vpc-public curl -s --connect-timeout 5 http://172.16.1.2:8081 &>/dev/null; then
    pass "Communication works after VPC peering"
else
    fail "Communication still blocked after peering"
fi

sudo kill $SERVER_PID2 2>/dev/null || true

# Test 12: Firewall Rules
section "12. Test: Firewall Rules (Security Groups)"

# Check if policy file exists
if [ -f "examples/policy.json" ]; then
    info "Applying firewall policy from examples/policy.json"
    sudo ./vpcctl.sh firewall examples/policy.json
    pass "Firewall policy applied"
else
    info "Policy file not found at examples/policy.json - skipping firewall test"
fi

# Test 13: Deploy Test Web Server in Public Subnet
section "13. Test: Deploy Web Server in Public Subnet"
info "Deploying Nginx-like server in public subnet"

# Start a web server in the public subnet
sudo ip netns exec ns-my-vpc-public python3 -m http.server 80 &>/dev/null &
WEB_SERVER_PID=$!
sleep 2

# Try to access from host
info "Testing access from host to public subnet web server..."
if curl -s --connect-timeout 5 http://10.0.1.2:80 &>/dev/null; then
    pass "Web server in public subnet is accessible"
else
    fail "Cannot access web server in public subnet"
fi

sudo kill $WEB_SERVER_PID 2>/dev/null || true

# Test 14: Deploy Test Web Server in Private Subnet
section "14. Test: Deploy Web Server in Private Subnet"
info "Deploying server in private subnet (should not be externally accessible)"

sudo ip netns exec ns-my-vpc-private python3 -m http.server 80 &>/dev/null &
PRIV_SERVER_PID=$!
sleep 2

# Try to access from host (should fail direct access)
info "Testing direct access from host to private subnet (should be blocked)..."
if curl -s --connect-timeout 3 http://10.0.2.2:80 &>/dev/null; then
    fail "Private subnet should not be directly accessible from host"
else
    pass "Private subnet correctly isolated from external access"
fi

sudo kill $PRIV_SERVER_PID 2>/dev/null || true

# Test 15: Verify Logging
section "15. Test: Verify Logging"
if [ -f "/var/log/vpcctl.log" ]; then
    info "Showing last 10 log entries from /var/log/vpcctl.log:"
    sudo tail -10 /var/log/vpcctl.log
    pass "Logging is working"
else
    fail "Log file not found"
fi

# Test 16: Test VPC Deletion
section "16. Test: Delete VPC and Cleanup"
info "Deleting my-vpc..."
sudo ./vpcctl.sh delete my-vpc

if ! ip link show br-my-vpc &>/dev/null; then
    pass "VPC deleted successfully"
else
    fail "VPC bridge still exists after deletion"
fi

info "Deleting other-vpc..."
sudo ./vpcctl.sh delete other-vpc

# Final Cleanup
section "17. Final Cleanup"
info "Running full cleanup..."
sudo ./vpcctl.sh cleanup

if [ -z "$(ip netns list | grep ns-)" ]; then
    pass "All namespaces cleaned up"
else
    fail "Some namespaces still exist"
fi

section "Testing Complete!"
echo ""
echo "All tests have been executed."
echo "Review the results above to verify your VPC implementation."
echo ""
