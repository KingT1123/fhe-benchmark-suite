#!/usr/bin/env bash
# power_guard.sh — runs one session of run_standard_campaign.sh so that no
# measurement is taken on battery power.
#
# Every 5 s it records the mains state and the battery level
# (<session>/power_log.csv, appended). When mains power is lost for 10 s it
# stops the session (the runner, then the running measurement container): the
# interrupted cell writes no valid output (it is moved to <session>/invalid/
# on resume), every completed cell is kept. When mains power has been back for 2 minutes it
# resumes the session with the same command (identical manifest: completed
# cells are skipped, the interrupted one is measured again). It ends when the
# session completes, or when the session stops for any reason other than a
# power loss (that stop is left for the operator to examine).
#
# It is not part of the measurement code (the manifest's code commit covers
# experiments/{openfhe,seal/src,scripts,config} only).
#
# Usage (HOST, from the repository root):
#   sudo bash experiments/tools/power_guard.sh s4
# Console of each attempt: campaign_<session>_guard<k>.log (repository root).
set -uo pipefail
SESSION="${1:?usage: power_guard.sh s1|s2|s3|s4|s5}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# DRY=1 (test only, no sudo): the short dry run of run_standard_campaign.sh;
# AC_FILE overrides the mains-state file (to simulate a power loss).
DRY="${DRY:-0}"; [ "$DRY" = 1 ] && NAME="_dry_$SESSION" || NAME="$SESSION"
SESSION_DIR="$ROOT/experiments/results/raw/standard_campaign/$NAME"
AC="${AC_FILE:-/sys/class/power_supply/ADP0/online}"
BAT=/sys/class/power_supply/BAT0/capacity
POLL=5; LOSS_POLLS=2; BACK_POLLS=24; MAX_ATTEMPTS=10
[ -r "$AC" ] || { echo "ERROR: $AC not readable" >&2; exit 1; }
mkdir -p "$SESSION_DIR"
PLOG="$SESSION_DIR/power_log.csv"
[ -f "$PLOG" ] || echo "timestamp,mains_online,battery_pct,event" > "$PLOG"
log() { echo "$(date -Iseconds),$(cat "$AC"),$(cat "$BAT" 2>/dev/null),$1" >> "$PLOG"; }
say() { echo "[guard $(date +%H:%M:%S)] $*"; }

wait_for_mains() {  # returns once mains has been on for BACK_POLLS polls in a row
    local ok=0
    while [ $ok -lt $BACK_POLLS ]; do
        if [ "$(cat "$AC")" = 1 ]; then ok=$((ok + 1)); else ok=0; fi
        log "waiting_for_mains"; sleep $POLL
    done
}

attempt=0
while [ $attempt -lt $MAX_ATTEMPTS ]; do
    if [ "$(cat "$AC")" != 1 ]; then
        say "on battery: waiting for mains power (2 min stable) before starting"
        log "start_blocked_on_battery"; wait_for_mains
    fi
    attempt=$((attempt + 1))
    CONSOLE="$ROOT/campaign_${NAME}_guard${attempt}.log"
    while [ -e "$CONSOLE" ]; do attempt=$((attempt + 1)); CONSOLE="$ROOT/campaign_${NAME}_guard${attempt}.log"; done
    say "starting attempt $attempt (console: ${CONSOLE#$ROOT/}; power profile: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null))"; log "start_attempt_${attempt}_profile_$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)"
    # own process group, so that a stop reaches the runner and everything it started
    ( cd "$ROOT" && DRY="$DRY" exec setsid bash experiments/openfhe/run_standard_campaign.sh "$SESSION" ) > "$CONSOLE" 2>&1 &
    RUN_PID=$!
    stopped_for_power=0; off=0
    while kill -0 "$RUN_PID" 2>/dev/null; do
        if [ "$(cat "$AC")" = 1 ]; then off=0; log "running"; else
            off=$((off + 1)); log "running_on_battery"
            if [ $off -ge $LOSS_POLLS ] && [ $stopped_for_power -eq 0 ]; then
                say "mains power lost: stopping the running measurement"
                log "stop_for_power_loss"; stopped_for_power=1
                kill -TERM -- "-$(ps -o pgid= "$RUN_PID" | tr -d ' ')" 2>/dev/null
                for img in seal-env openfhe-env; do docker ps -q --filter "ancestor=$img" | xargs -r docker stop >/dev/null; done
            fi
        fi
        sleep $POLL
    done
    wait "$RUN_PID"; rc=$?
    if grep -q "^Session $NAME complete" "$CONSOLE"; then
        say "session $SESSION complete"; log "session_complete"; exit 0
    fi
    if [ $stopped_for_power -eq 0 ]; then
        say "the session stopped by itself (exit $rc), not for power: see ${CONSOLE#$ROOT/}. Not resuming."
        log "session_stopped_rc_$rc"; exit "$rc"
    fi
    say "stopped for power loss (exit $rc); will resume when mains is back"
    # a cell stopped after its output was written but before its configuration
    # card: its record is incomplete -- set aside (kept), so it is measured again
    for f in "$SESSION_DIR"/*_cat*_*.csv; do
        [ -e "$f" ] || continue
        t="$(basename "$f" .csv)"
        [ -f "$SESSION_DIR/meta/$t.meta" ] && continue
        q="$SESSION_DIR/invalid/$(date +%Y%m%dT%H%M%S)_power_stop"; mkdir -p "$q"
        for g in "$f" "$SESSION_DIR/checks/${t}_check.csv" "$SESSION_DIR/memory/${t}_mem.log"; do [ -e "$g" ] && mv "$g" "$q/"; done
        say "set aside $t (stopped before its configuration card was written)"; log "set_aside_$t"
    done
    wait_for_mains
done
say "too many attempts ($MAX_ATTEMPTS); stopping"; log "max_attempts"; exit 1
