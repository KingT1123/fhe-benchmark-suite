#!/usr/bin/env bash
# set_aside_cell.sh — moves one valid campaign cell out of the statistics, so
# that resuming its session measures it again. Nothing is deleted: the cell's
# CSV, check file, configuration card and memory log go to
# <session>/<folder>/ (aggregate.py reads only the top level of a session).
# Used when a cell is valid but was measured under conditions that differ
# from the rest of its session (recorded in INCIDENTS.md).
#
# Usage (HOST, sudo: session directories are root-owned; DRY=1 only prints):
#   sudo bash experiments/tools/set_aside_cell.sh s4 openfhe_bfv_N16384_cat1_add set_aside_reduced_power_20261028
set -euo pipefail
SESSION="${1:?usage: set_aside_cell.sh SESSION TAG FOLDER}"; TAG="${2:?TAG}"; FOLDER="${3:?FOLDER}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$ROOT/experiments/results/raw/standard_campaign/$SESSION"
D="$S/$FOLDER"
[ -e "$D/$TAG.csv" ] && { echo "ERROR: $D/$TAG.csv already exists" >&2; exit 1; }
run() { if [ "${DRY:-0}" = 1 ]; then echo "would: $*"; else "$@"; fi; }
run mkdir -p "$D/checks" "$D/meta" "$D/memory"
n=0
for pair in "$TAG.csv:" "checks/${TAG}_check.csv:checks/" "meta/$TAG.meta:meta/" "memory/${TAG}_mem.log:memory/"; do
    src="$S/${pair%%:*}"; dst="$D/${pair#*:}"
    [ -e "$src" ] || { echo "MISSING: $src" >&2; exit 1; }
    run mv "$src" "$dst"; n=$((n + 1))
done
echo "moved $n files (expected 4) of $TAG to $SESSION/$FOLDER"
