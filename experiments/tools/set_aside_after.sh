#!/usr/bin/env bash
# set_aside_after.sh — energy/memory campaign: sets aside every ENERGY
# invocation of a session that started after a given time, so that resuming
# the session (same command, same plan) measures them again. Used only for a
# disturbance with a recorded external cause, decided by time, never by the
# values (campaign/ENERGY_CAMPAIGN_RULES.md, section 6). Memory invocations
# are not touched. Nothing is deleted: the CSV, check file and configuration
# card go to <session>/invalid/<timestamp>_<label>/ (aggregate.py and the
# validator read only the top level), and each is listed in set_aside.csv.
#
# Usage (HOST, repository root; sudo: session directories are root-owned):
#   sudo bash experiments/tools/set_aside_after.sh SESSION ISO_TIME LABEL "REASON"
#   DRY=1 bash ... only prints what it would move.
set -euo pipefail
SESSION="${1:?usage: set_aside_after.sh SESSION ISO_TIME LABEL REASON}"; CUT="${2:?ISO_TIME}"
LABEL="${3:?LABEL}"; REASON="${4:?REASON}"
EXP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$EXP/results/raw/energy_campaign/$SESSION"
[ -f "$S/cell_times.csv" ] || { echo "ERROR: $S/cell_times.csv missing" >&2; exit 1; }
REL="results/raw/energy_campaign/$SESSION/invalid/$(date +%Y%m%dT%H%M%S)_$LABEL"
mapfile -t TAGS < <(python3 - "$S/cell_times.csv" "$CUT" <<'PY'
import csv, sys
from datetime import datetime
cut = datetime.fromisoformat(sys.argv[2])
last = {}
for r in csv.DictReader(open(sys.argv[1])):
    if r["exit_code"] == "0":
        last[r["tag"]] = datetime.fromisoformat(r["start"])   # last valid attempt
for t, a in sorted(last.items()):
    if "_energy" in t and a >= cut:
        print(t)
PY
)
echo "${#TAGS[@]} energy invocations of $SESSION started at or after $CUT"
[ "${DRY:-0}" = 1 ] && { printf '  would set aside: %s\n' "${TAGS[@]}"; exit 0; }
mkdir -p "$EXP/$REL"
n=0
for t in "${TAGS[@]}"; do
    [ -e "$S/$t.csv" ] || { echo "ERROR: $S/$t.csv missing (already set aside?)" >&2; exit 1; }
    for f in "$S/$t.csv" "$S/checks/${t}_check.csv" "$S/meta/$t.meta"; do
        [ -e "$f" ] && mv "$f" "$EXP/$REL/"
    done
    echo "$(date -Iseconds),$t,$REASON,$REL" >> "$S/set_aside.csv"
    n=$((n + 1))
done
echo "set aside $n invocations (files kept in $REL); resume the session to measure them again"
