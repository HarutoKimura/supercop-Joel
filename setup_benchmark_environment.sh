#!/bin/bash

# Benchmarking Environment Setup Script
# Based on CryptOpt paper methodology for noise reduction and reproducible measurements
# Addresses reviewer concerns about microbenchmarking environment setup

set -e

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Cryptographic Assembly Benchmarking Environment Setup ===${NC}"
echo "This script configures the system for reproducible microbenchmarking"
echo "based on the CryptOpt paper methodology."
echo

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   echo -e "${RED}Error: This script should NOT be run as root.${NC}"
   echo "Run as a regular user. The script will prompt for sudo when needed."
   exit 1
fi

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to get CPU information
get_cpu_info() {
    echo -e "${BLUE}=== CPU Information ===${NC}"
    echo "CPU Model: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "CPU Cores: $(nproc)"
    echo "CPU Threads: $(grep -c processor /proc/cpuinfo)"
    
    # Check for relevant CPU features
    echo -e "\n${YELLOW}CPU Features (relevant to benchmarking):${NC}"
    if grep -q 'rdtscp' /proc/cpuinfo; then
        echo "✓ RDTSCP support detected"
    else
        echo "✗ RDTSCP not detected (will fall back to RDTSC)"
    fi
    
    if grep -q 'adx' /proc/cpuinfo; then
        echo "✓ ADCX/ADOX support detected"
    else
        echo "✗ ADCX/ADOX not detected"
    fi
    
    if grep -q 'bmi2' /proc/cpuinfo; then
        echo "✓ BMI2 support detected"
    else
        echo "✗ BMI2 not detected"
    fi
    echo
}

# Function to disable SMT/Hyperthreading
disable_smt() {
    echo -e "${YELLOW}=== Checking SMT/Hyperthreading Status ===${NC}"
    
    # Check current SMT status
    if [ -f /sys/devices/system/cpu/smt/active ]; then
        smt_status=$(cat /sys/devices/system/cpu/smt/active)
        if [ "$smt_status" = "1" ]; then
            echo "SMT/Hyperthreading is currently ENABLED"
            echo "Based on CryptOpt analysis: SMT has minimal impact on optimization"
            echo "but disabling can reduce noise for precise measurements"
            read -p "Disable SMT for this session? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "Disabling SMT/Hyperthreading..."
                echo off | sudo tee /sys/devices/system/cpu/smt/control > /dev/null
                echo "✓ SMT disabled for this session"
            else
                echo "Keeping SMT enabled"
            fi
        else
            echo "✓ SMT/Hyperthreading is already disabled"
        fi
    else
        echo "SMT control not available on this system"
    fi
    echo
}

# Function to set CPU governor and disable turbo boost
configure_cpu_frequency() {
    echo -e "${YELLOW}=== CPU Frequency Configuration ===${NC}"
    
    # Check if cpupower is available
    if ! command_exists cpupower; then
        echo -e "${RED}cpupower not found. Installing...${NC}"
        sudo apt-get update > /dev/null 2>&1
        sudo apt-get install -y linux-tools-generic linux-tools-$(uname -r) > /dev/null 2>&1
    fi
    
    # Show current governor
    echo "Current CPU governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    
    # Set performance governor
    echo "Setting CPU governor to 'performance'..."
    sudo cpupower frequency-set -g performance > /dev/null 2>&1
    echo "✓ CPU governor set to performance"
    
    # Disable turbo boost
    echo "Disabling Turbo Boost for stable frequency..."
    
    # Intel turbo boost
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null
        echo "✓ Intel Turbo Boost disabled"
    # AMD boost
    elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost > /dev/null
        echo "✓ AMD Boost disabled"
    else
        echo "⚠ Turbo boost control not found (may not be supported)"
    fi
    
    # Set minimum frequency for consistency
    # This follows CryptOpt's approach of setting frequency to minimum during evaluation
    available_freqs=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null || echo "")
    if [ -n "$available_freqs" ]; then
        min_freq=$(echo $available_freqs | awk '{print $NF}')
        echo "Setting CPU frequency to minimum available: ${min_freq}kHz"
        sudo cpupower frequency-set -f ${min_freq}kHz > /dev/null 2>&1
        echo "✓ CPU frequency fixed to ${min_freq}kHz"
    else
        echo "⚠ Could not determine available frequencies"
    fi
    
    echo
}

# Function to configure ASLR
configure_aslr() {
    echo -e "${YELLOW}=== Address Space Layout Randomization (ASLR) ===${NC}"
    
    current_aslr=$(cat /proc/sys/kernel/randomize_va_space)
    echo "Current ASLR setting: $current_aslr (0=disabled, 1=conservative, 2=full)"
    
    if [ "$current_aslr" != "0" ]; then
        echo "ASLR can introduce measurement noise by varying memory layout"
        read -p "Disable ASLR for this session? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo 0 | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
            echo "✓ ASLR disabled for this session"
        else
            echo "Keeping ASLR enabled"
        fi
    else
        echo "✓ ASLR is already disabled"
    fi
    echo
}

# Function to setup CPU core isolation
setup_core_pinning() {
    echo -e "${YELLOW}=== CPU Core Isolation Setup ===${NC}"
    
    total_cores=$(nproc)
    echo "Total CPU cores available: $total_cores"
    
    # Reserve last core for OS activity (following CryptOpt methodology)
    if [ $total_cores -gt 2 ]; then
        benchmark_core=$((total_cores - 2))  # Use second-to-last core
        os_core=$((total_cores - 1))         # Reserve last core for OS
        
        echo "Recommended setup:"
        echo "  - Core $benchmark_core: Dedicated to benchmark processes"
        echo "  - Core $os_core: Reserved for OS activity"
        echo "  - Cores 0-$((benchmark_core-1)): Available for other processes"
        
        # Create core pinning helper script
        cat > run_benchmark_pinned.sh << EOF
#!/bin/bash
# CPU Core Pinning Helper Script
# Generated by setup_benchmark_environment.sh

BENCHMARK_CORE=$benchmark_core

echo "Running benchmark on dedicated core \$BENCHMARK_CORE..."
exec taskset -c \$BENCHMARK_CORE "\$@"
EOF
        chmod +x run_benchmark_pinned.sh
        
        echo "✓ Created 'run_benchmark_pinned.sh' helper script"
        echo "Usage: ./run_benchmark_pinned.sh cargo run <args>"
    else
        echo "⚠ System has only $total_cores cores - core pinning may not be beneficial"
    fi
    echo
}

# Function to check and stop unnecessary services
optimize_system_noise() {
    echo -e "${YELLOW}=== System Noise Optimization ===${NC}"
    
    echo "Checking for noise-causing services..."
    
    # List of services that can cause measurement noise
    noisy_services=("cron" "atd" "systemd-timesyncd" "irqbalance" "thermald")
    
    for service in "${noisy_services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo "⚠ $service is running (may cause measurement noise)"
            read -p "Stop $service for this session? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                sudo systemctl stop "$service"
                echo "✓ Stopped $service"
            fi
        fi
    done
    
    # Suggest moving IRQs away from benchmark core
    if [ -f run_benchmark_pinned.sh ]; then
        echo "For advanced users: Consider moving IRQ handling away from benchmark core"
        echo "This requires manual configuration of /proc/irq/*/smp_affinity"
    fi
    
    echo
}

# Function to verify taskset availability
check_taskset() {
    echo -e "${YELLOW}=== Checking Required Tools ===${NC}"
    
    if ! command_exists taskset; then
        echo -e "${RED}taskset not found. Installing util-linux...${NC}"
        sudo apt-get update > /dev/null 2>&1
        sudo apt-get install -y util-linux > /dev/null 2>&1
    fi
    echo "✓ taskset available"
    
    if ! command_exists numactl; then
        echo "numactl not found. Installing for NUMA awareness..."
        sudo apt-get install -y numactl > /dev/null 2>&1
    fi
    echo "✓ numactl available"
    echo
}

# Function to create measurement verification script
create_verification_script() {
    echo -e "${YELLOW}=== Creating Environment Verification Script ===${NC}"
    
    cat > verify_benchmark_environment.sh << 'EOF'
#!/bin/bash
# Environment Verification Script for Benchmarking

echo "=== Benchmark Environment Status ==="

# Check CPU governor
echo "CPU Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"

# Check turbo boost status
if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    turbo_status=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
    if [ "$turbo_status" = "1" ]; then
        echo "Intel Turbo Boost: DISABLED ✓"
    else
        echo "Intel Turbo Boost: ENABLED ⚠"
    fi
elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
    boost_status=$(cat /sys/devices/system/cpu/cpufreq/boost)
    if [ "$boost_status" = "0" ]; then
        echo "AMD Boost: DISABLED ✓"
    else
        echo "AMD Boost: ENABLED ⚠"
    fi
fi

# Check ASLR
aslr_status=$(cat /proc/sys/kernel/randomize_va_space)
echo "ASLR Status: $aslr_status (0=disabled ✓, 1-2=enabled ⚠)"

# Check SMT
if [ -f /sys/devices/system/cpu/smt/active ]; then
    smt_status=$(cat /sys/devices/system/cpu/smt/active)
    if [ "$smt_status" = "0" ]; then
        echo "SMT/Hyperthreading: DISABLED ✓"
    else
        echo "SMT/Hyperthreading: ENABLED (acceptable)"
    fi
fi

# Check current frequency
current_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
echo "Current CPU Frequency: ${current_freq}kHz"

echo
echo "Environment is ready for benchmarking!"
EOF
    
    chmod +x verify_benchmark_environment.sh
    echo "✓ Created 'verify_benchmark_environment.sh' verification script"
    echo
}

# Function to create environment restoration script
create_restore_script() {
    echo -e "${YELLOW}=== Creating Environment Restoration Script ===${NC}"
    
    # Save current settings
    current_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    current_aslr=$(cat /proc/sys/kernel/randomize_va_space)
    
    cat > restore_system_defaults.sh << EOF
#!/bin/bash
# System Defaults Restoration Script
# Generated by setup_benchmark_environment.sh

echo "Restoring system to default settings..."

# Restore CPU governor
echo "Restoring CPU governor to: $current_governor"
sudo cpupower frequency-set -g $current_governor > /dev/null 2>&1

# Enable turbo boost
if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null
    echo "Intel Turbo Boost re-enabled"
elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
    echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost > /dev/null
    echo "AMD Boost re-enabled"
fi

# Restore ASLR
echo $current_aslr | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
echo "ASLR restored to: $current_aslr"

# Re-enable SMT if it was disabled
if [ -f /sys/devices/system/cpu/smt/control ]; then
    echo on | sudo tee /sys/devices/system/cpu/smt/control > /dev/null
    echo "SMT/Hyperthreading re-enabled"
fi

echo "System restored to defaults"
EOF
    
    chmod +x restore_system_defaults.sh
    echo "✓ Created 'restore_system_defaults.sh' restoration script"
    echo
}

# Main execution
main() {
    get_cpu_info
    check_taskset
    disable_smt
    configure_cpu_frequency
    configure_aslr
    setup_core_pinning
    optimize_system_noise
    create_verification_script
    create_restore_script
    
    echo -e "${GREEN}=== Setup Complete ===${NC}"
    echo
    echo "Generated scripts:"
    echo "  - run_benchmark_pinned.sh: Run benchmarks with core pinning"
    echo "  - verify_benchmark_environment.sh: Check current environment status"
    echo "  - restore_system_defaults.sh: Restore original system settings"
    echo
    echo -e "${BLUE}Next steps:${NC}"
    echo "1. Run: ./verify_benchmark_environment.sh (verify setup)"
    echo "2. Run benchmarks: ./run_benchmark_pinned.sh cargo run curve25519 mul 5"
    echo "3. After benchmarking: ./restore_system_defaults.sh (restore defaults)"
    echo
    echo -e "${YELLOW}Important notes:${NC}"
    echo "- These settings are temporary and will reset on reboot"
    echo "- Run verify_benchmark_environment.sh before each benchmark session"
    echo "- Consider running benchmarks during low system activity"
    echo "- Multiple runs with statistical analysis are recommended"
}

# Run main function
main 