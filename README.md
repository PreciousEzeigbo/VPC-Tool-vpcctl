# VPC Management Tool (vpcctl)

A Linux-based Virtual Private Cloud (VPC) implementation using network namespaces, bridges, and iptables.

## Features

- Create isolated VPCs with custom CIDR blocks
- Public and private subnet support
- Inter-subnet communication within VPCs
- NAT gateway for internet access (public subnets)
- VPC isolation (default deny between VPCs)
- VPC peering for cross-VPC communication
- Firewall rules via JSON policies
- Comprehensive logging

## Requirements

- Linux (tested on Ubuntu/Debian)
- Root access (sudo)
- Python 3 (for testing)
- curl (for testing)

## Quick Start

### 1. Setup

```bash
chmod +x vpcctl.sh test_vpc.sh
# OR
make setup
```

### 2. Run Tests (Recommended)

```bash
sudo ./test_vpc.sh
# OR
make test
```

This runs 14 automated tests demonstrating all features.

### 3. Using Makefile (Easiest)

**Create a VPC:**

```bash
make create-vpc VPC=prod-vpc CIDR=10.0.0.0/16
```

**Add public subnet:**

```bash
make add-public VPC=prod-vpc SUBNET=web SUBNET_CIDR=10.0.1.0/24
```

**Add private subnet:**

```bash
make add-private VPC=prod-vpc SUBNET=db SUBNET_CIDR=10.0.2.0/24
```

**List and show VPCs:**

```bash
make list
make show VPC=prod-vpc
```

**Apply firewall:**

```bash
make firewall POLICY=examples/policy.json
```

**Cleanup:**

```bash
make clean
```

### 4. Manual Usage (Without Makefile)

**Create a VPC:**

```bash
sudo ./vpcctl.sh create my-vpc 10.0.0.0/16
```

**Add subnets:**

```bash
sudo ./vpcctl.sh add-subnet my-vpc public 10.0.1.0/24 public
sudo ./vpcctl.sh add-subnet my-vpc private 10.0.2.0/24 private
```

**Apply firewall rules:**

```bash
sudo ./vpcctl.sh firewall examples/policy.json
```

**List VPCs:**

```bash
sudo ./vpcctl.sh list
```

**Clean up:**

```bash
sudo ./vpcctl.sh cleanup
```

## Commands

| Command                                 | Description                       |
| --------------------------------------- | --------------------------------- |
| `create <vpc> <cidr>`                   | Create a new VPC                  |
| `delete <vpc>`                          | Delete VPC and all resources      |
| `add-subnet <vpc> <name> <cidr> <type>` | Add subnet (type: public/private) |
| `peer <vpc1> <vpc2>`                    | Create VPC peering connection     |
| `firewall <policy.json>`                | Apply firewall rules              |
| `list`                                  | List all VPCs                     |
| `show <vpc>`                            | Show VPC details                  |
| `cleanup`                               | Remove all resources              |

## Firewall Policy Format

Create JSON files with firewall rules:

```json
{
  "subnet": "10.0.1.0/24",
  "ingress": [
    { "port": 80, "protocol": "tcp", "action": "allow" },
    { "port": 22, "protocol": "tcp", "action": "deny" }
  ]
}
```

## Architecture

- **Network Namespaces**: Isolated network environments for subnets
- **Linux Bridges**: Act as VPC routers (br-{vpc-name})
- **veth Pairs**: Virtual ethernet connections between namespaces
- **iptables**: NAT, forwarding rules, and firewall policies

## Configuration Details

| Variable           | Description                                       |
| ------------------ | ------------------------------------------------- |
| VPC_NAME           | Unique name for the virtual VPC                   |
| CIDR_BLOCK         | Base IP range (e.g., 10.0.0.0/16)                 |
| PUBLIC_SUBNET      | Subnet that allows NAT internet access            |
| PRIVATE_SUBNET     | Subnet without internet access                    |
| INTERNET_INTERFACE | Host's outbound network interface (auto-detected) |

## Logs

All operations are logged to `/var/log/vpcctl.log`

## Project Structure

```
.
├── vpcctl.sh              # Main VPC control script
├── test_vpc.sh            # Automated test suite (14 tests)
├── examples/
│   └── policy.json        # Sample firewall policy
└── README.md
```

## Example Workflow

```bash
# Create VPC
sudo ./vpcctl.sh create prod-vpc 10.0.0.0/16

# Add public subnet with internet access
sudo ./vpcctl.sh add-subnet prod-vpc web 10.0.1.0/24 public

# Add private subnet (no internet)
sudo ./vpcctl.sh add-subnet prod-vpc db 10.0.2.0/24 private

# Apply firewall rules
sudo ./vpcctl.sh firewall examples/policy.json

# Test connectivity between subnets
sudo ip netns exec ns-prod-vpc-web ping -c 2 10.0.2.2

# View configuration
sudo ./vpcctl.sh show prod-vpc

# Cleanup when done
sudo ./vpcctl.sh cleanup
```

## License

HNG Stage 4 DevOps Project
