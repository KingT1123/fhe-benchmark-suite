#!/usr/bin/env bash
# run_energy_validation.sh — part B of the limited energy/memory validation
# requested after the Standard campaign: the dedicated energy/memory
# procedure (the SEAL campaign's, scripts/run_energy_memory_docker.sh) run AT
# FIXED FREQUENCY (boost disabled, part A: tools/fixed_freq_test.sh) on a few
# BFV, BGV and CKKS operations of both libraries. One call = one session;
# the validation runs two sessions (e1, e2) at different times.
#
# Cells: validation/energy_plan_fixedfreq.csv (make_energy_fixedfreq_plan.py):
# BFV/BGV/CKKS N=8192 category 1; keygen, encrypt, multiply, relinearize;
# SEAL and OpenFHE. Per cell, as in the SEAL campaign protocol:
#   * energy, TWICE (energy1, energy2): one invocation, RAPL read around the
#     timed window only, 30 reps after 2 warm-up, inner loop from the plan
#     (~50 ms window), and the harness's own idle reading (6 s settle, 4 s
#     window, 2 s ramp) just before the reps;
#   * memory, 3 invocations (mem1..3) at inner loop 1, 10 reps after 2
#     warm-up, observed peak process RSS (VmHWM, --peak-rss-out).
# Invocations in randomized order (seed recorded). Fail-closed (session_lib.sh).
#
# Machine state, verified throughout:
#   * boost disabled for the whole session (restored on exit), governor
#     performance; the pinned core's effective frequency and temperature
#     every second (thermal_log.csv, session_lib.sh);
#   * power_log.csv every second: phase, mains, battery, boost, platform
#     profile and the package energy counter. Part A showed that, at the same
#     frequency and load, the package draws ~25% less on battery: an
#     invocation during which mains power was lost, even for one second, is
#     moved aside (set_aside.csv) and measured again once mains has been back
#     for 2 minutes;
#   * two session idle windows (idle_start, idle_end: 30 s settle, then 60 s
#     with nothing running), read from power_log.csv, as an independent check
#     of the per-invocation idle readings (baseline sensitivity, aggregate.py).
#
# Usage (HOST, repository root; sudo: boost, governor, RAPL):
#   sudo bash experiments/openfhe/run_energy_validation.sh e1
# Output: experiments/results/raw/energy_validation/<session>/
# Statistics: cd experiments/scripts && python3 aggregate.py --scenario=energy_validation
# Test without sudo: DRY=1 (tiny counts, no RAPL, nothing written to the
# system, session _dry_<session>); AC_FILE overrides the mains-state file.
set -euo pipefail
SESSION="${1:?usage: run_energy_validation.sh e1|e2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP="$(cd "$SCRIPT_DIR/.." && pwd)"
DRY="${DRY:-0}"
NAME="$([ "$DRY" = 1 ] && echo _dry_)$SESSION"
SESSION_DIR="$EXP/results/raw/energy_validation/$NAME"
LOG_DIR="$EXP/results/logs/energy_validation/$NAME"
TASKSET_CORE="${TASKSET_CORE:-0}"
PLAN="$SCRIPT_DIR/validation/energy_plan_fixedfreq.csv"
AC="${AC_FILE:-/sys/class/power_supply/ADP0/online}"
BAT=/sys/class/power_supply/BAT0/capacity
BOOST=/sys/devices/system/cpu/cpufreq/boost
PROFILE=/sys/firmware/acpi/platform_profile
RAPL_HOST_DIR="$(realpath /sys/class/powercap/intel-rapl:0)"
if [ "$DRY" = 1 ]; then ER=2; EW=1; MR=2; MW=1; SETTLE=0; IDLE=1; RAMP=0; IDLE_SETTLE_S=2; IDLE_WIN_S=3; BACK_S=5
else ER=30; EW=2; MR=10; MW=2; SETTLE=6; IDLE=4; RAMP=2; IDLE_SETTLE_S=30; IDLE_WIN_S=60; BACK_S=120; fi
DOCKER_EXTRA=()
source "$SCRIPT_DIR/session_lib.sh"

[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || { echo "run with sudo (or DRY=1 to test)" >&2; exit 1; }
for f in "$EXP/seal/build/bench_seal" "$EXP/openfhe/build/bench_openfhe" "$PLAN"; do
    [ -e "$f" ] || { echo "ERROR: $f missing" >&2; exit 1; }
done
[ "$(cat "$AC")" = 1 ] || { echo "ERROR: the charger must be plugged in at the start" >&2; exit 1; }

SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
session_start "energy_validation_$SESSION" "$SEED"

# ---- boost off for the whole session; restored on exit with the governor
setw() { [ "$DRY" = 1 ] && return 0; echo "$2" > "$1"; }
OLD_BOOST="$(cat "$BOOST")"
POWER_PID=""
energy_cleanup() {
    [ -n "$POWER_PID" ] && kill "$POWER_PID" 2>/dev/null || true
    setw "$BOOST" "$OLD_BOOST" || true
    session_cleanup
    echo "boost restored ($OLD_BOOST)"
}
trap energy_cleanup EXIT
trap 'exit 130' INT TERM
setw "$BOOST" 0
[ "$DRY" = 1 ] || [ "$(cat "$BOOST")" = 0 ] || { echo "ERROR: could not disable boost" >&2; exit 1; }
{
    echo "energy validation session: $SESSION (fixed frequency, part B)"
    echo "boost (as found): $OLD_BOOST; set to: $([ "$DRY" = 1 ] && echo "unchanged (dry run)" || cat "$BOOST")"
    echo "platform_profile: $(cat "$PROFILE" 2>/dev/null)"
    echo "energy: $ER reps + $EW warm-up x 2 invocations; idle ${SETTLE}s settle + ${IDLE}s window, ${RAMP}s ramp; memory: 3 x ($MR reps + $MW warm-up) at inner loop 1"
    echo "session idle windows: ${IDLE_SETTLE_S}s settle + ${IDLE_WIN_S}s, at start and end"
    echo "plan: ${PLAN#$EXP/}"
} >> "$SESSION_DIR/cpu_state.txt"
[ "$DRY" = 1 ] || echo "$(date -Iseconds),energy_validation_$SESSION,$SEED,120" >> "$EXP/results/run_metadata.csv"

# ---- power log, every second; .battery_seen is created whenever mains is off
PLOG="$SESSION_DIR/power_log.csv"
[ -f "$PLOG" ] || echo "timestamp,phase,mains_online,battery_pct,boost,platform_profile,package_energy_uj" > "$PLOG"
echo start > "$SESSION_DIR/.phase"
( while true; do
      m="$(cat "$AC")"
      [ "$m" = 1 ] || touch "$SESSION_DIR/.battery_seen"
      echo "$(date -Iseconds),$(cat "$SESSION_DIR/.phase"),$m,$(cat "$BAT" 2>/dev/null),$(cat "$BOOST"),$(cat "$PROFILE" 2>/dev/null),$(cat "$RAPL_HOST_DIR/energy_uj" 2>/dev/null)" >> "$PLOG"
      sleep 1
  done ) &
POWER_PID=$!
SET_ASIDE="$SESSION_DIR/set_aside.csv"
[ -f "$SET_ASIDE" ] || echo "timestamp,tag,reason" > "$SET_ASIDE"

wait_for_mains() {  # returns at once on mains; after a loss, once mains has been back BACK_S seconds
    [ "$(cat "$AC")" = 1 ] && [ ! -e "$SESSION_DIR/.battery_seen" ] && return 0
    echo "   [$(date +%H:%M:%S)] ON BATTERY: paused. Measurement resumes ${BACK_S}s after the charger is back."
    local ok=0
    while [ $ok -lt "$BACK_S" ]; do
        [ "$(cat "$AC")" = 1 ] && ok=$((ok + 1)) || ok=0
        sleep 1
    done
    rm -f "$SESSION_DIR/.battery_seen"
    echo "   [$(date +%H:%M:%S)] mains back for ${BACK_S}s: resuming"
}

idle_window() {  # $1 = idle_start | idle_end; repeated if mains is lost during it
    while true; do
        wait_for_mains
        echo "[$(date +%H:%M:%S)] session idle window $1: ${IDLE_SETTLE_S}s settle, then ${IDLE_WIN_S}s with nothing running"
        echo "${1}_settle" > "$SESSION_DIR/.phase"; sleep "$IDLE_SETTLE_S"
        echo "$1" > "$SESSION_DIR/.phase"; sleep "$IDLE_WIN_S"
        echo cells > "$SESSION_DIR/.phase"
        [ -e "$SESSION_DIR/.battery_seen" ] || return 0
        echo "$(date -Iseconds),$1,mains lost during the window (repeated)" >> "$SET_ASIDE"
    done
}

G=(git -c safe.directory='*' -C "$EXP/..")
CELL_META="commit $("${G[@]}" rev-parse HEAD); images seal-env $(docker image inspect -f '{{.Id}}' seal-env) openfhe-env $(docker image inspect -f '{{.Id}}' openfhe-env); boost 0; energy $ER+$EW settle $SETTLE idle $IDLE ramp $RAMP; memory $MR+$MW"

[ -f "$SESSION_DIR/idle_done_start" ] || { idle_window idle_start; touch "$SESSION_DIR/idle_done_start"; }

CELLS=()
while IFS=, read -r LIB SCHEME N CAT OP LAT INNER_E; do
    for k in 1 2; do CELLS+=("$LIB,$SCHEME,$OP,$INNER_E,energy$k"); done
    for k in 1 2 3; do CELLS+=("$LIB,$SCHEME,$OP,1,mem$k"); done
done < <(tail -n +2 "$PLAN")
mapfile -t ORDER < <(printf '%s\n' "${CELLS[@]}" | \
    shuf --random-source=<(openssl enc -aes-256-ctr -pass pass:"$SEED" -nosalt </dev/zero 2>/dev/null))
DOCKER_EXTRA=(--mount "type=bind,source=$RAPL_HOST_DIR,target=/rapl,readonly")
RUN_DIRECT=1   # harness started directly: no polling process draws power during a RAPL window
echo cells > "$SESSION_DIR/.phase"
i=0
for cell in "${ORDER[@]}"; do
    i=$((i + 1))
    IFS=, read -r LIB SCHEME OP INNER_E KIND <<< "$cell"
    TAG="${LIB}_${SCHEME,,}_N8192_cat1_${OP}_${KIND}"
    [ "$DRY" = 1 ] && [ "$INNER_E" -gt 3 ] && INNER_E=3
    while true; do
        wait_for_mains
        echo "[$i/${#ORDER[@]}] $(date +%H:%M:%S) $TAG  (CPU $(temp_c) °C, $(awk '{printf "%.2f GHz", $1/1e6}' "$CPUF/cpuinfo_avg_freq" 2>/dev/null))"
        if [[ "$KIND" == energy* ]]; then
            E_ARGS=(--rapl-dir=/rapl --idle-settle-seconds="$SETTLE" --idle-seconds="$IDLE" --ramp-seconds="$RAMP")
            [ "$DRY" = 1 ] && E_ARGS=()
            run_cell "$LIB" "$TAG" $((ER + EW)) "$EW" --scheme="$SCHEME" --N=8192 --category=1 --operation="$OP" \
                --reps="$ER" --warmup="$EW" --inner-loop="$INNER_E" "${E_ARGS[@]}"
        else
            run_cell "$LIB" "$TAG" $((MR + MW)) "$MW" --scheme="$SCHEME" --N=8192 --category=1 --operation="$OP" \
                --reps="$MR" --warmup="$MW" --inner-loop=1 \
                --peak-rss-out="/work/${SESSION_DIR#$EXP/}/memory/${TAG}_peak.log"
        fi
        sleep 2   # the power log samples every second: covers a loss in the invocation's last second
        [ -e "$SESSION_DIR/.battery_seen" ] || break
        echo "   mains lost during $TAG: moved aside, measured again"
        echo "$(date -Iseconds),$TAG,mains lost during the invocation" >> "$SET_ASIDE"
        [ -e "$SESSION_DIR/memory/${TAG}_peak.log" ] && mv "$SESSION_DIR/memory/${TAG}_peak.log" "$SESSION_DIR/$TAG.csv.peak_log"
        quarantine "$TAG"   # moves $TAG.csv* (the peak log with it): kept, never deleted
    done
done

[ -f "$SESSION_DIR/idle_done_end" ] || { idle_window idle_end; touch "$SESSION_DIR/idle_done_end"; }
echo done > "$SESSION_DIR/.phase"
echo "Session $NAME complete: $(date +%H:%M:%S). Statistics: cd experiments/scripts && python3 aggregate.py --scenario=energy_validation"
