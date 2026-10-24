#!/usr/bin/env bash
# run_standard_campaign.sh — the OpenFHE Standard-scenario campaign (latency),
# with SEAL measured in the SAME session for every configuration, by the
# validated components: bench_openfhe / bench_seal (every repetition checked,
# fail-closed output), session_lib.sh (validation of every cell, stop on any
# failure, quarantine on resume, thermal/frequency log, cell times) and
# scripts/validate_cell.py.
#
# Sessions: campaign/standard_sessions.csv assigns each of the 17 eligible
# configurations (probe/eligible_v2.csv) to one session (s1..s5); "dry" is the
# short validation run on representative CKKS, BFV and BGV configurations.
# Per configuration, the cells are exactly the operations established as valid
# for it (eligible_v2.csv, column ops), for OpenFHE and for SEAL, plus
# OpenFHE's two diagnostics where defined (decrypt_full with decrypt,
# add_inplace with add; end-to-end API costs, never compared as equivalent).
# Protocol of the SEAL Standard campaign: 100 measured repetitions after 5
# warm-up, inner loop 1000 (keygen and rotate: one call per repetition), one
# process per cell pinned to one core, governor "performance", the cells of a
# session in randomized order (seed recorded and reused on resume).
#
# Configuration record and safe resume:
#   * the session manifest (<session>/manifest.txt) records the code commit,
#     the sha256 of both harness binaries, the Docker image identifiers, the
#     sha256 of eligible_v2.csv and param_grid.csv, the repetition counts, the
#     order seed and the complete ordered cell list; on resume the manifest
#     must be IDENTICAL, otherwise the session stops (exit 4) -- measurements
#     made under a different configuration are never reused;
#   * every cell also carries its own configuration card (meta/<tag>.meta,
#     see session_lib.sh), checked before it is skipped on resume;
#   * a real session refuses to start if experiments/{openfhe,seal/src,
#     scripts,config} have uncommitted changes.
#
# Usage (HOST, sudo for the CPU governor), one session per night:
#   sudo bash experiments/openfhe/run_standard_campaign.sh s1     (s1 .. s5)
# Dry run (no sudo; 2 repetitions, inner loop 5; directory _dry_<session>):
#   DRY=1 bash experiments/openfhe/run_standard_campaign.sh dry
# Output: experiments/results/raw/standard_campaign/<session>/.
# Statistics: cd experiments/scripts && python3 aggregate.py --scenario=openfhe_standard
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSION="${1:?usage: run_standard_campaign.sh s1|s2|s3|s4|s5|dry}"
DRY="${DRY:-0}"
if [ "$DRY" = 1 ]; then REPS=2; WARMUP=1; INNER=5; NAME="_dry_$SESSION"
else REPS=100; WARMUP=5; INNER=1000; NAME="$SESSION"; fi
[ "$SESSION" = dry ] && [ "$DRY" != 1 ] && { echo "the 'dry' session is for DRY=1 only" >&2; exit 1; }
ROWS=$((REPS + WARMUP))
SESSION_DIR="$EXP/results/raw/standard_campaign/$NAME"
LOG_DIR="$EXP/results/logs/standard_campaign/$NAME"
TASKSET_CORE="${TASKSET_CORE:-0}"
DOCKER_EXTRA=()
source "$SCRIPT_DIR/session_lib.sh"

G=(git -c safe.directory='*' -C "$EXP/..")
DIRTY=$("${G[@]}" status --porcelain -- experiments/openfhe experiments/seal/src experiments/scripts experiments/config | wc -l)
if [ "$DIRTY" -ne 0 ] && [ "$DRY" != 1 ]; then
    echo "ERROR: uncommitted changes in experiments/{openfhe,seal/src,scripts,config} -- commit them first," >&2
    echo "so that every measurement is traceable to one code version:" >&2
    "${G[@]}" status --porcelain -- experiments/openfhe experiments/seal/src experiments/scripts experiments/config >&2
    exit 1
fi
for f in "$EXP/seal/build/bench_seal" "$EXP/openfhe/build/bench_openfhe"; do
    [ -x "$f" ] || { echo "ERROR: $f not built (bash experiments/seal/docker_build_and_run.sh; bash experiments/openfhe/docker_build.sh)" >&2; exit 1; }
done

# ---- cell list of the session (deterministic), then its manifest
mapfile -t CELLS < <(python3 - "$SCRIPT_DIR/campaign/standard_sessions.csv" "$SCRIPT_DIR/probe/eligible_v2.csv" "$SESSION" <<'EOF'
import csv, sys
sessions, eligible, sid = sys.argv[1:]
el = {(r["scheme"], r["N"], r["category"]): r for r in csv.DictReader(open(eligible))}
for r in csv.DictReader(open(sessions)):
    if r["session"] != sid:
        continue
    key = (r["scheme"], r["N"], r["category"])
    ops = el[key]["ops"].split()                     # operations established as valid for this configuration
    diag = (["decrypt_full"] if "decrypt" in ops else []) + (["add_inplace"] if "add" in ops else [])
    for op in ops + diag:
        print(f"openfhe,{key[0]},{key[1]},{key[2]},{op}")
    for op in ops:
        print(f"seal,{key[0]},{key[1]},{key[2]},{op}")
EOF
)
[ ${#CELLS[@]} -gt 0 ] || { echo "ERROR: no cells for session '$SESSION' in campaign/standard_sessions.csv" >&2; exit 1; }

mkdir -p "$SESSION_DIR"
OLD_SEED=$(grep -m1 '^run_order_seed: ' "$SESSION_DIR/manifest.txt" 2>/dev/null | cut -d' ' -f2 || true)
SEED="${OLD_SEED:-${RUN_ORDER_SEED:-$RANDOM$RANDOM}}"
mapfile -t ORDER < <(printf '%s\n' "${CELLS[@]}" | \
    shuf --random-source=<(openssl enc -aes-256-ctr -pass pass:"$SEED" -nosalt </dev/zero 2>/dev/null))
sha() { sha256sum "$1" | cut -d' ' -f1; }
MANIFEST=$(
    echo "scenario: openfhe_standard_campaign"
    echo "session: $SESSION$([ "$DRY" = 1 ] && echo ' (DRY RUN)')"
    echo "run_order_seed: $SEED"
    echo "code commit: $("${G[@]}" rev-parse HEAD); uncommitted changes in experiments/{openfhe,seal/src,scripts,config}: $DIRTY"
    echo "bench_openfhe sha256: $(sha "$EXP/openfhe/build/bench_openfhe")"
    echo "bench_seal sha256: $(sha "$EXP/seal/build/bench_seal")"
    echo "images: seal-env $(docker image inspect -f '{{.Id}}' seal-env) openfhe-env $(docker image inspect -f '{{.Id}}' openfhe-env)"
    echo "eligible_v2.csv sha256: $(sha "$SCRIPT_DIR/probe/eligible_v2.csv")"
    echo "param_grid.csv sha256: $(sha "$EXP/config/param_grid.csv")"
    echo "repetitions: $REPS measured + $WARMUP warm-up; inner loop $INNER (keygen, rotate: 1); taskset core $TASKSET_CORE"
    echo "cells (${#ORDER[@]}, in execution order):"
    printf '  %s\n' "${ORDER[@]}"
)
if [ -f "$SESSION_DIR/manifest.txt" ]; then
    if [ "$(cat "$SESSION_DIR/manifest.txt")" != "$MANIFEST" ]; then
        echo "STOPPED: this session was started under a DIFFERENT configuration; its measurements are not reused." >&2
        { diff "$SESSION_DIR/manifest.txt" <(echo "$MANIFEST") || true; } | sed 's/^/   /' >&2
        echo "Keep the existing directory (move it aside) or use another session name." >&2
        exit 4
    fi
    echo "Resuming session $NAME (manifest identical)."
else
    echo "$MANIFEST" > "$SESSION_DIR/manifest.txt"
    [ "$DRY" = 1 ] || echo "$(date -Iseconds),openfhe_standard_$SESSION,$SEED,${#ORDER[@]}" >> "$EXP/results/run_metadata.csv"
fi

session_start "openfhe_standard_campaign_$SESSION" "$SEED"
echo "repetitions: $REPS measured + $WARMUP warm-up; inner loop $INNER" >> "$SESSION_DIR/cpu_state.txt"
cp "$SESSION_DIR/cpu_state.txt" "$SESSION_DIR/cpu_state_$(date +%Y%m%dT%H%M%S).txt"   # one record per (re)start
echo "Session $NAME: ${#ORDER[@]} cells, order seed $SEED, governor enforced: $GOV_OK"

i=0; T0=$(date +%s)
for cell in "${ORDER[@]}"; do
    i=$((i + 1))
    IFS=, read -r LIB S N C OP <<< "$cell"
    TAG="${LIB}_${S,,}_N${N}_cat${C}_${OP}"
    { [ "$OP" = "keygen" ] || [ "$OP" = "rotate" ]; } && LOOP=1 || LOOP=$INNER
    ARGS=(--scheme="$S" --N="$N" --category="$C" --operation="$OP" --reps="$REPS" --warmup="$WARMUP" --inner-loop="$LOOP")
    CELL_META=$(printf '%s\n' "$(echo "$MANIFEST" | sed -n '4,9p')" "library: $LIB" "args: ${ARGS[*]}")
    ELAPSED=$(( $(date +%s) - T0 ))
    echo "[$i/${#ORDER[@]}] $(date +%H:%M:%S) $TAG  (CPU $(temp_c) °C; elapsed $((ELAPSED / 3600))h$(((ELAPSED % 3600) / 60))m)"
    run_cell "$LIB" "$TAG" "$ROWS" "$WARMUP" "${ARGS[@]}"
done
echo "Session $NAME complete: $(date +%H:%M:%S). Next: cd experiments/scripts && python3 aggregate.py --scenario=openfhe_standard"
