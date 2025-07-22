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
