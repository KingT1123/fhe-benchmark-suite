#!/usr/bin/env bash
# run_energy_campaign.sh — one session of the SEAL-OpenFHE energy/memory
# campaign at fixed frequency (boost disabled, mains power only). It is
# run_energy_validation.sh (validated, tag energy-validation-v1) generalized
# to any plan of cells: same per-invocation protocol, same power log, same
# set-aside-and-repeat rule on a loss of mains power, same session idle
# windows. Rules: campaign/ENERGY_CAMPAIGN_RULES.md.
#
# A plan (campaign/energy_plan_*.csv, written by campaign/make_energy_plans.py)
# gives, per cell: library, scheme, N, category, operation, inner loop,
# energy repetitions, number of energy invocations (energy1..k), number of
# memory invocations (mem1..k: inner loop 1, 10 repetitions after 2 warm-up,
# observed peak process RSS) and an optional label. Rotation is refused: its
# energy and peak RSS are reported as not available.
# Output tag: <library>_<scheme>_N<N>_cat<category>_<operation>[_<label>]_<energyK|memK>
#
# The session's plan is copied into the session directory; a resumed session
# must use an identical plan. Invocations run in randomized order (seed
# recorded). At the end, scripts/verify_energy_session.py checks that every
# planned invocation produced its files; its report is session_check.txt.
#
# Usage (HOST, repository root; sudo: boost, governor, RAPL):
#   sudo bash experiments/openfhe/run_energy_campaign.sh <session> <plan.csv>
# Output: experiments/results/raw/energy_campaign/<session>/
# GUARD_TEST=1: plan order kept, and the operator is asked to unplug the
#   charger at the start of the first energy invocation (stage-1 guard test).
# Test without sudo: DRY=1 (tiny counts, no RAPL, nothing written to the
# system, session _dry_<session>); AC_FILE overrides the mains-state file.
set -euo pipefail
SESSION="${1:?usage: run_energy_campaign.sh <session> <plan.csv>}"
PLAN_SRC="${2:?usage: run_energy_campaign.sh <session> <plan.csv>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP="$(cd "$SCRIPT_DIR/.." && pwd)"
DRY="${DRY:-0}"
GUARD_TEST="${GUARD_TEST:-0}"
if [ "$DRY" = 1 ]; then NAME="_dry_$SESSION"; else NAME="$SESSION"; fi
SESSION_DIR="$EXP/results/raw/energy_campaign/$NAME"
LOG_DIR="$EXP/results/logs/energy_campaign/$NAME"
TASKSET_CORE="${TASKSET_CORE:-0}"
AC="${AC_FILE:-/sys/class/power_supply/ADP0/online}"
BAT=/sys/class/power_supply/BAT0/capacity
BOOST=/sys/devices/system/cpu/cpufreq/boost
PROFILE=/sys/firmware/acpi/platform_profile
RAPL_HOST_DIR="$(realpath /sys/class/powercap/intel-rapl:0)"
if [ "$DRY" = 1 ]; then EW=1; MR=2; MW=1; SETTLE=0; IDLE=1; RAMP=0; IDLE_SETTLE_S=2; IDLE_WIN_S=3; BACK_S=5
else EW=2; MR=10; MW=2; SETTLE=6; IDLE=4; RAMP=2; IDLE_SETTLE_S=30; IDLE_WIN_S=60; BACK_S=120; fi
DOCKER_EXTRA=()
source "$SCRIPT_DIR/session_lib.sh"

[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || { echo "run with sudo (or DRY=1 to test)" >&2; exit 1; }
for f in "$EXP/seal/build/bench_seal" "$EXP/openfhe/build/bench_openfhe" "$PLAN_SRC"; do
    [ -e "$f" ] || { echo "ERROR: $f missing" >&2; exit 1; }
done
if grep -q ',rotate,' "$PLAN_SRC"; then
    echo "ERROR: the plan contains rotation; its energy and peak RSS are not measured (not available)" >&2; exit 1
fi
[ "$(cat "$AC")" = 1 ] || { echo "ERROR: the charger must be plugged in at the start" >&2; exit 1; }

# ---- the plan is part of the session: copied once, identical on resume
mkdir -p "$SESSION_DIR"
PLAN="$SESSION_DIR/plan.csv"
if [ -f "$PLAN" ]; then
    cmp -s "$PLAN" "$PLAN_SRC" || { echo "STOPPED: session $NAME exists with a DIFFERENT plan (see $PLAN). Use another session name." >&2; exit 4; }
else
    cp "$PLAN_SRC" "$PLAN"
fi

SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
session_start "energy_campaign_$SESSION" "$SEED"

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
if [ "$DRY" = 1 ]; then BOOST_NOW="unchanged (dry run)"; else BOOST_NOW="$(cat "$BOOST")"; fi
{
    echo "energy campaign session: $SESSION (fixed frequency)"
    echo "plan: ${PLAN_SRC##*/} (sha256 $(sha256sum "$PLAN" | cut -c1-16)), $(($(wc -l < "$PLAN") - 1)) cells"
    echo "boost (as found): $OLD_BOOST; set to: $BOOST_NOW"
    echo "platform_profile: $(cat "$PROFILE" 2>/dev/null)"
    echo "energy: plan repetitions + $EW warm-up per invocation; idle ${SETTLE}s settle + ${IDLE}s window, ${RAMP}s ramp; memory: $MR reps + $MW warm-up at inner loop 1"
    echo "session idle windows: ${IDLE_SETTLE_S}s settle + ${IDLE_WIN_S}s, at start and end"
    echo "guard test: $GUARD_TEST"
} >> "$SESSION_DIR/cpu_state.txt"

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
[ -f "$SET_ASIDE" ] || echo "timestamp,tag,reason,kept_in" > "$SET_ASIDE"

wait_for_mains() {  # returns at once on mains; after a loss, once mains has been back BACK_S seconds
    [ "$(cat "$AC")" = 1 ] && [ ! -e "$SESSION_DIR/.battery_seen" ] && return 0
    echo "   [$(date +%H:%M:%S)] ON BATTERY: paused. Measurement resumes ${BACK_S}s after the charger is back."
    local ok=0
    while [ $ok -lt "$BACK_S" ]; do
        if [ "$(cat "$AC")" = 1 ]; then ok=$((ok + 1)); else ok=0; fi
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
        echo "$(date -Iseconds),$1,mains lost during the window (repeated)," >> "$SET_ASIDE"
    done
}

G=(git -c safe.directory='*' -C "$EXP/..")
CELL_META="commit $("${G[@]}" rev-parse HEAD); images seal-env $(docker image inspect -f '{{.Id}}' seal-env) openfhe-env $(docker image inspect -f '{{.Id}}' openfhe-env); plan $(sha256sum "$PLAN" | cut -c1-16); boost 0; energy warm-up $EW settle $SETTLE idle $IDLE ramp $RAMP; memory $MR+$MW"

[ -f "$SESSION_DIR/idle_done_start" ] || { idle_window idle_start; touch "$SESSION_DIR/idle_done_start"; }

CELLS=()
while IFS=, read -r LIB SCHEME N CAT OP LAT INNER_E EREPS ERUNS MRUNS LABEL; do
    for k in $(seq 1 "$ERUNS"); do CELLS+=("$LIB,$SCHEME,$N,$CAT,$OP,$INNER_E,$EREPS,$LABEL,energy$k"); done
    for k in $(seq 1 "$MRUNS"); do CELLS+=("$LIB,$SCHEME,$N,$CAT,$OP,1,$MR,$LABEL,mem$k"); done
done < <(tail -n +2 "$PLAN")
if [ "$GUARD_TEST" = 1 ]; then ORDER=("${CELLS[@]}"); else
    mapfile -t ORDER < <(printf '%s\n' "${CELLS[@]}" | \
        shuf --random-source=<(openssl enc -aes-256-ctr -pass pass:"$SEED" -nosalt </dev/zero 2>/dev/null))
fi
DOCKER_EXTRA=(--mount "type=bind,source=$RAPL_HOST_DIR,target=/rapl,readonly")
RUN_DIRECT=1   # harness started directly: no polling process draws power during a RAPL window
echo cells > "$SESSION_DIR/.phase"
i=0
ASKED=0
for cell in "${ORDER[@]}"; do
    i=$((i + 1))
    IFS=, read -r LIB SCHEME N CAT OP INNER_E REPS LABEL KIND <<< "$cell"
    TAG="${LIB}_${SCHEME,,}_N${N}_cat${CAT}_${OP}${LABEL:+_$LABEL}_${KIND}"
    if [ "$DRY" = 1 ]; then
        [ "$INNER_E" -gt 3 ] && INNER_E=3
        [ "$REPS" -gt 2 ] && REPS=2
    fi
    while true; do
        wait_for_mains
        echo "[$i/${#ORDER[@]}] $(date +%H:%M:%S) $TAG  (CPU $(temp_c) °C, $(awk '{printf "%.2f GHz", $1/1e6}' "$CPUF/cpuinfo_avg_freq" 2>/dev/null))"
        if [ "$GUARD_TEST" = 1 ] && [ "$ASKED" = 0 ] && [[ "$KIND" == energy* ]]; then
            ASKED=1
            echo; echo "   >>> GUARD TEST: UNPLUG THE CHARGER NOW, COUNT TO 5, THEN PLUG IT BACK IN <<<"; echo
        fi
        ARGS=(--scheme="$SCHEME" --N="$N" --category="$CAT" --operation="$OP")
        if [[ "$KIND" == energy* ]]; then
            E_ARGS=(--rapl-dir=/rapl --idle-settle-seconds="$SETTLE" --idle-seconds="$IDLE" --ramp-seconds="$RAMP")
            [ "$DRY" = 1 ] && E_ARGS=()
            run_cell "$LIB" "$TAG" $((REPS + EW)) "$EW" "${ARGS[@]}" --reps="$REPS" --warmup="$EW" --inner-loop="$INNER_E" "${E_ARGS[@]}"
        else
            run_cell "$LIB" "$TAG" $((MR + MW)) "$MW" "${ARGS[@]}" --reps="$MR" --warmup="$MW" --inner-loop=1 \
                --peak-rss-out="/work/${SESSION_DIR#$EXP/}/memory/${TAG}_peak.log"
        fi
        sleep 2   # the power log samples every second: covers a loss in the invocation's last second
        [ -e "$SESSION_DIR/.battery_seen" ] || break
        echo "   mains lost during $TAG: set aside (kept), measured again"
        [ -e "$SESSION_DIR/memory/${TAG}_peak.log" ] && mv "$SESSION_DIR/memory/${TAG}_peak.log" "$SESSION_DIR/$TAG.csv.peak_log"
        KEPT="$(quarantine "$TAG" | sed -n 's/.* to //p')"   # moves $TAG.csv* (the peak log with it): kept, never deleted
        echo "$(date -Iseconds),$TAG,mains lost during the invocation,$KEPT" >> "$SET_ASIDE"
    done
done

[ -f "$SESSION_DIR/idle_done_end" ] || { idle_window idle_end; touch "$SESSION_DIR/idle_done_end"; }
echo done > "$SESSION_DIR/.phase"
echo "Session $NAME complete: $(date +%H:%M:%S)."
VERIFY_ARGS=("$SESSION_DIR"); [ "$DRY" = 1 ] && VERIFY_ARGS+=(--dry)
python3 "$EXP/scripts/verify_energy_session.py" "${VERIFY_ARGS[@]}" | tee "$SESSION_DIR/session_check.txt"
