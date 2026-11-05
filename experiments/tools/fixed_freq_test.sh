#!/usr/bin/env bash
# fixed_freq_test.sh — part A of the energy/memory validation: does a fixed
# CPU frequency (boost disabled) hold on this laptop, on mains AND on battery?
#
# No FHE code runs here. One core (TASKSET_CORE, default 0, the core the
# harnesses are pinned to) is kept busy by a plain loop while, every second,
# the mains state, battery level, boost state, effective and requested
# frequency of that core, CPU temperature, fan speeds and the package energy
# counter (RAPL) are recorded. Phases, in order:
#   boost_on_mains   3 min  reference: the configuration of the latency campaign
#   fixed_mains     10 min  boost disabled, on mains
#   wait_unplug             the operator unplugs the charger (prompted)
#   fixed_battery   10 min  boost disabled, on battery
#   wait_replug             the operator plugs the charger back (prompted; 3 min max)
# On exit (normal, Ctrl-C or error) boost and the governor are put back as
# they were. Nothing else on the system is changed.
#
# Usage (HOST, from the repository root, sudo: boost, governor and RAPL):
#   sudo bash experiments/tools/fixed_freq_test.sh
# Output: experiments/results/raw/energy_validation/fixed_freq_<timestamp>/
#   freq_log.csv (one row per second), state_before.txt, summary.txt
# Test without sudo: DRY=1 (phases of 10 s, nothing written to the system;
# AC_FILE overrides the mains-state file to simulate unplugging).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRY="${DRY:-0}"
CORE="${TASKSET_CORE:-0}"
AC="${AC_FILE:-/sys/class/power_supply/ADP0/online}"
BAT=/sys/class/power_supply/BAT0/capacity
CPUF="/sys/devices/system/cpu/cpu$CORE/cpufreq"
BOOST=/sys/devices/system/cpu/cpufreq/boost
RAPL=/sys/class/powercap/intel-rapl:0/energy_uj
PROFILE=/sys/firmware/acpi/platform_profile
if [ "$DRY" = 1 ]; then T_REF=10; T_FIX=10; T_REPLUG=10; else T_REF=180; T_FIX=600; T_REPLUG=180; fi
[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || { echo "run with sudo (or DRY=1 to test)" >&2; exit 1; }
hwmon_by_name() { for h in /sys/class/hwmon/hwmon*; do [ "$(cat "$h/name" 2>/dev/null)" = "$1" ] && { echo "$h"; return; }; done; }
K10="$(hwmon_by_name k10temp)"; ASUS="$(hwmon_by_name asus)"
OUT="$ROOT/experiments/results/raw/energy_validation/$([ "$DRY" = 1 ] && echo _dry_)fixed_freq_$(date +%Y%m%dT%H%M%S)"
mkdir -p "$OUT"
LOG="$OUT/freq_log.csv"
echo "timestamp,phase,mains_online,battery_pct,boost,effective_freq_khz,requested_freq_khz,temp_millic,cpu_fan_rpm,gpu_fan_rpm,package_energy_uj,platform_profile" > "$LOG"

OLD_BOOST="$(cat "$BOOST")"; OLD_GOV="$(cat "$CPUF/scaling_governor")"
{ echo "date: $(date -Iseconds)"; echo "kernel: $(uname -r)"; echo "cpu: $(lscpu | sed -n 's/^Model name: *//p')"
  echo "driver: $(cat "$CPUF/scaling_driver") ($(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null))"
  echo "boost: $OLD_BOOST"; echo "governor (core $CORE): $OLD_GOV"
  echo "energy_performance_preference: $(cat "$CPUF/energy_performance_preference" 2>/dev/null)"
  echo "platform_profile: $(cat "$PROFILE" 2>/dev/null)"
  echo "max frequency (amd_pstate_max_freq, kHz): $(cat "$CPUF/amd_pstate_max_freq" 2>/dev/null)"
  echo "mains: $(cat "$AC"); battery: $(cat "$BAT")%"; } > "$OUT/state_before.txt"

setw() { [ "$DRY" = 1 ] && { echo "   (dry) would write $2 to $1"; return; }; echo "$2" > "$1"; }
LOAD_PID=""
restore() {
    [ -n "$LOAD_PID" ] && kill "$LOAD_PID" 2>/dev/null
    setw "$BOOST" "$OLD_BOOST"; setw "$CPUF/scaling_governor" "$OLD_GOV"
    echo "boost and governor restored ($OLD_BOOST, $OLD_GOV)"
}
trap restore EXIT
trap 'exit 130' INT TERM

sample() {  # one row of the log
    echo "$(date -Iseconds),$1,$(cat "$AC"),$(cat "$BAT" 2>/dev/null),$(cat "$BOOST"),$(cat "$CPUF/cpuinfo_avg_freq" 2>/dev/null),$(cat "$CPUF/scaling_cur_freq" 2>/dev/null),$(cat "$K10/temp1_input" 2>/dev/null),$(cat "$ASUS/fan1_input" 2>/dev/null),$(cat "$ASUS/fan2_input" 2>/dev/null),$(cat "$RAPL" 2>/dev/null),$(cat "$PROFILE" 2>/dev/null)" >> "$LOG"
}
run_phase() {  # name seconds [stop condition "mains=0|1"]; returns 0 = full duration, 2 = stopped by the condition
    local n=0
    while [ $n -lt "$2" ]; do
        sample "$1"; n=$((n + 1))
        [ -n "${3:-}" ] && [ "$(cat "$AC")" = "${3#mains=}" ] && return 2
        [ $((n % 60)) = 0 ] && echo "   $1: $((n / 60)) min, $(awk '{printf "%.2f GHz", $1/1e6}' "$CPUF/cpuinfo_avg_freq" 2>/dev/null), $(awk '{printf "%.0f C", $1/1000}' "$K10/temp1_input" 2>/dev/null), mains $(cat "$AC")"
        sleep 1
    done
    return 0
}

[ "$(cat "$AC")" = 1 ] || { echo "the charger must be plugged in at the start" >&2; exit 1; }
setw "$CPUF/scaling_governor" performance
taskset -c "$CORE" sh -c 'while :; do :; done' & LOAD_PID=$!
echo "[$(date +%H:%M:%S)] load started on core $CORE. Phase 1/3: boost ON, on mains ($((T_REF / 60)) min)"
run_phase boost_on_mains "$T_REF"
setw "$BOOST" 0
echo "[$(date +%H:%M:%S)] boost OFF. Phase 2/3: on mains ($((T_FIX / 60)) min)"
run_phase fixed_mains "$T_FIX"
echo
echo "   >>> UNPLUG THE CHARGER NOW <<<   (the test waits for it)"
echo
until [ "$(cat "$AC")" = 0 ]; do sample wait_unplug; sleep 1; done
echo "[$(date +%H:%M:%S)] on battery. Phase 3/3: boost OFF, on battery ($((T_FIX / 60)) min) -- keep the charger unplugged"
run_phase fixed_battery "$T_FIX" mains=1
[ $? = 2 ] && echo "   the charger was plugged back before the end of phase 3: battery phase incomplete"
echo
echo "   >>> PLUG THE CHARGER BACK IN NOW <<<"
echo
run_phase wait_replug "$T_REPLUG" mains=1
[ $? = 0 ] && echo "   (still on battery after $((T_REPLUG / 60)) min)"
kill "$LOAD_PID" 2>/dev/null; LOAD_PID=""

python3 - "$LOG" > "$OUT/summary.txt" <<'EOF'
import csv, statistics as st, sys
from datetime import datetime
rows = list(csv.DictReader(open(sys.argv[1])))
print(f"{'phase':16} {'s':>4} {'freq median':>12} {'min':>6} {'max':>6} {'temp med':>9} {'pkg W med':>10}")
for ph in ("boost_on_mains", "fixed_mains", "fixed_battery"):
    r = [x for x in rows if x["phase"] == ph]
    f = [int(x["effective_freq_khz"]) / 1e6 for x in r if x["effective_freq_khz"]]
    t = [int(x["temp_millic"]) / 1000 for x in r if x["temp_millic"]]
    w = []
    for a, b in zip(r, r[1:]):
        if a["package_energy_uj"] and b["package_energy_uj"] and int(b["package_energy_uj"]) >= int(a["package_energy_uj"]):
            dt = (datetime.fromisoformat(b["timestamp"]) - datetime.fromisoformat(a["timestamp"])).total_seconds()
            if dt > 0:
                w.append((int(b["package_energy_uj"]) - int(a["package_energy_uj"])) / 1e6 / dt)
    if not f:
        print(f"{ph:16} {len(r):>4}  no samples"); continue
    print(f"{ph:16} {len(r):>4} {st.median(f):>9.3f} GHz {min(f):>6.2f} {max(f):>6.2f} {st.median(t) if t else float('nan'):>7.1f} C "
          f"{st.median(w) if w else float('nan'):>8.1f} W")
EOF
echo; cat "$OUT/summary.txt"; echo; echo "Results: ${OUT#$ROOT/}"
