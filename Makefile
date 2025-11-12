.PHONY: help test install clean setup demo create-vpc add-public add-private

# Default values
VPC ?= my-vpc
CIDR ?= 10.0.0.0/16
SUBNET ?= public
SUBNET_CIDR ?= 10.0.1.0/24

# Default target
help:
	@echo "VPC Management Tool - Makefile"
	@echo ""
	@echo "Quick Commands:"
	@echo "  make test                    - Run full test suite (14 tests)"
	@echo "  make demo                    - Run quick demo of VPC features"
	@echo "  make clean                   - Cleanup all VPC resources"
	@echo "  make logs                    - Show recent logs"
	@echo ""
	@echo "VPC Management (with custom names):"
	@echo "  make create-vpc VPC=prod-vpc CIDR=10.0.0.0/16"
	@echo "  make add-public VPC=prod-vpc SUBNET=web SUBNET_CIDR=10.0.1.0/24"
	@echo "  make add-private VPC=prod-vpc SUBNET=db SUBNET_CIDR=10.0.2.0/24"
	@echo "  make list"
	@echo "  make show VPC=prod-vpc"
	@echo "  make delete VPC=prod-vpc"
	@echo ""
	@echo "Advanced:"
	@echo "  make firewall POLICY=examples/policy.json"
	@echo "  make peer VPC1=vpc1 VPC2=vpc2"
	@echo "  make install                 - Install vpcctl system-wide"
	@echo ""
	@echo "Default values: VPC=$(VPC) CIDR=$(CIDR)"
	@echo ""

# Setup permissions
setup:
	@echo "Setting up script permissions..."
	chmod +x vpcctl.sh test_vpc.sh
	@echo "✓ Scripts are now executable"

# Run test suite
test: setup
	@echo "Running VPC test suite..."
	sudo ./test_vpc.sh

# Quick demo
demo: setup
	@echo "Running quick VPC demo..."
	@echo ""
	sudo ./vpcctl.sh create demo-vpc 10.0.0.0/16
	sudo ./vpcctl.sh add-subnet demo-vpc public 10.0.1.0/24 public
	sudo ./vpcctl.sh add-subnet demo-vpc private 10.0.2.0/24 private
	sudo ./vpcctl.sh list
	sudo ./vpcctl.sh show demo-vpc
	@echo ""
	@echo "Demo complete! Cleaning up in 3 seconds..."
	@sleep 3
	sudo ./vpcctl.sh delete demo-vpc

# Install to system
install: setup
	@echo "Installing vpcctl to /usr/local/bin..."
	sudo cp vpcctl.sh /usr/local/bin/vpcctl
	sudo chmod +x /usr/local/bin/vpcctl
	@echo "✓ vpcctl installed! You can now run 'sudo vpcctl <command>'"

# Cleanup all resources
clean:
	@echo "Cleaning up all VPC resources..."
	sudo ./vpcctl.sh cleanup || true
	@echo "✓ Cleanup complete"

# Show logs
logs:
	@if [ -f /var/log/vpcctl.log ]; then \
		echo "Recent vpcctl logs:"; \
		echo "=================="; \
		sudo tail -20 /var/log/vpcctl.log; \
	else \
		echo "No logs found at /var/log/vpcctl.log"; \
	fi

# Create VPC with custom name
create-vpc: setup
	@echo "Creating VPC: $(VPC) with CIDR: $(CIDR)"
	sudo ./vpcctl.sh create $(VPC) $(CIDR)
	@echo "✓ VPC '$(VPC)' created successfully"

# Add public subnet
add-public: setup
	@echo "Adding public subnet '$(SUBNET)' to VPC '$(VPC)'"
	sudo ./vpcctl.sh add-subnet $(VPC) $(SUBNET) $(SUBNET_CIDR) public
	@echo "✓ Public subnet '$(SUBNET)' added successfully"

# Add private subnet
add-private: setup
	@echo "Adding private subnet '$(SUBNET)' to VPC '$(VPC)'"
	sudo ./vpcctl.sh add-subnet $(VPC) $(SUBNET) $(SUBNET_CIDR) private
	@echo "✓ Private subnet '$(SUBNET)' added successfully"

# Delete VPC
delete: setup
	@echo "Deleting VPC: $(VPC)"
	sudo ./vpcctl.sh delete $(VPC)
	@echo "✓ VPC '$(VPC)' deleted successfully"

# List VPCs
list: setup
	sudo ./vpcctl.sh list

# Show VPC details
show: setup
	@echo "Showing details for VPC: $(VPC)"
	sudo ./vpcctl.sh show $(VPC)

# Remove obsolete add-subnet target
# Add subnet
# (Removed - use add-public or add-private instead)

# Apply firewall
firewall: setup
	@if [ -z "$(POLICY)" ]; then \
		POLICY="examples/policy.json"; \
	fi; \
	echo "Applying firewall policy: $$POLICY"; \
	sudo ./vpcctl.sh firewall $$POLICY

# VPC Peering
peer: setup
	@if [ -z "$(VPC1)" ] || [ -z "$(VPC2)" ]; then \
		echo "Usage: make peer VPC1=my-vpc VPC2=other-vpc"; \
		exit 1; \
	fi
	@echo "Creating peering between $(VPC1) and $(VPC2)"
	sudo ./vpcctl.sh peer $(VPC1) $(VPC2)
	@echo "✓ VPC peering established"
