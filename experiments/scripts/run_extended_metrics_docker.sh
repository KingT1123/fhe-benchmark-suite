#!/usr/bin/env bash
# run_extended_metrics_docker.sh — Chapter 3's three previously-deferred
# metrics (storage, noise-budget evolution, CKKS error accumulation), plus
# config_metadata (the parameter facts needed to interpret all of them),
# through Docker.
#
# One Docker call per (scheme, N, category) cell PER METRIC -- not per the
# six timed operations from Scenario A/B/Edge-Batch. size/noise_trace/
# ckks_error/config_metadata each cover their own artifacts/steps internally
# in one call (see bench_seal.cpp's header comment), so the "one call = one
# cell" convention here means one call per (scheme, N, category, metric),
# not one call per (scheme, N, category, six-operations).
#
# No RAPL/peak-memory wrapping (unlike run_standard_docker.sh /
# run_edge_batch_docker.sh's use of _inner_measure.sh): these three are not
# latency/energy/memory measurements, so that machinery doesn't apply.
#
# noise_trace is BFV/BGV-only and ckks_error is CKKS-only, but this script
# invokes both operations for BOTH schemes uniformly -- the scheme-mismatch
# skip (skipped_not_applicable_ckks / skipped_not_applicable_bfv) is
# handled inside bench_seal.cpp itself (returns before build_context is
# even called), so the sweep script doesn't need its own branching for it.
#
# Raw CSVs go to results/raw/extended_metrics/ (a subdirectory, not the
# shared results/raw/), same reasoning as run_edge_batch_docker.sh: keeps
# these out of aggregate.py's --scenario=standard glob (`seal_*.csv` minus
# "_constrained" would otherwise silently sweep these in).
#
# --trace-reps=10 for both noise_trace and ckks_error: pinned explicitly
# here rather than relying on bench_seal's compiled-in default, since this
# is the actual value the sweep uses and should be visible/auditable, not
# implicit.
#
# Grid override: set GRID=/path/to/subset.csv (must live under
# experiments/config/ so it's inside the Docker mount) to sweep a subset
# instead of the full grid, e.g. for a small verification run before
# committing to the full 144-row sweep.

set -euo pipefail
IMAGE="${IMAGE:-seal-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GRID_HOST="${GRID:-$EXPERIMENTS_DIR/config/param_grid.csv}"
GRID_CONTAINER="/work/config/$(basename "$GRID_HOST")"
RAW_DIR="$EXPERIMENTS_DIR/results/raw/extended_metrics"
LOG_DIR="$EXPERIMENTS_DIR/results/logs/extended_metrics"
TRACE_REPS=10

mkdir -p "$RAW_DIR" "$LOG_DIR"

# --- Extra-rigor items 2/5/6/7 adaptation note: this script measures four
# fully DETERMINISTIC metrics (serialized byte sizes, noise-budget bit
# counts, CKKS error, config facts) -- no latency or energy is measured at
# all (see header comment: no RAPL/peak-memory wrapping, no taskset core
# pinning). bench_seal's internal RNG is freshly re-seeded to a fixed value
# at the start of every process invocation (see bench_seal.cpp), so each
# cell's result is already independent of wall-clock timing, CPU frequency,
# thermal state, AND run order by construction -- there is nothing here for
# idle-power subtraction, governor enforcement, or run-order randomization
# to actually protect against.
#   - Item 2 (idle-power baseline): SKIPPED. Adding it would introduce a new
#     RAPL dependency into a script that deliberately has none, purely to
#     produce a number with nothing to subtract it from here.
#   - Item 5 (governor) and item 7 (temperature logging): kept anyway, for
#     infrastructure consistency with every other run script and because
#     they're free (no measurement here depends on either), not because
#     they change any result.
#   - Item 6 (randomized order): kept for the same consistency reason --
#     harmless and free, even though determinism means it can't introduce
#     OR remove any bias here.
GOVERNOR_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
BOOST_FILE="/sys/devices/system/cpu/cpufreq/boost"
INTEL_NOTURBO_FILE="/sys/devices/system/cpu/intel_pstate/no_turbo"
CPU_STATE_LOG="$LOG_DIR/cpu_state.txt"

ORIGINAL_GOVERNOR="$(cat "$GOVERNOR_FILE" 2>/dev/null || echo "")"
GOVERNOR_ENFORCED=0
if [ -n "$ORIGINAL_GOVERNOR" ]; then
    if echo performance > "$GOVERNOR_FILE" 2>/dev/null; then
        GOVERNOR_ENFORCED=1
    else
        echo "WARNING: could not write $GOVERNOR_FILE (needs root) -- governor NOT enforced, only logged below." >&2
    fi
fi

TEMP_LOG="$LOG_DIR/temperature_log.csv"
TEMP_SOURCE=""
for zone in /sys/class/thermal/thermal_zone*/; do
    if [ -r "${zone}type" ] && grep -qiE "x86_pkg_temp|cpu" "${zone}type" 2>/dev/null && [ -r "${zone}temp" ]; then
        TEMP_SOURCE="${zone}temp"; break
    fi
done
if [ -z "$TEMP_SOURCE" ]; then
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$zone" ] && TEMP_SOURCE="$zone" && break
    done
fi
TEMP_LOGGER_PID=""
if [ -n "$TEMP_SOURCE" ]; then
    echo "timestamp,temp_millic,source" > "$TEMP_LOG"
    ( while true; do
          echo "$(date -Iseconds),$(cat "$TEMP_SOURCE" 2>/dev/null || echo ''),$TEMP_SOURCE" >> "$TEMP_LOG"
          sleep 5
      done ) &
    TEMP_LOGGER_PID=$!
    echo "Temperature logging started (PID $TEMP_LOGGER_PID, source=$TEMP_SOURCE) -> $TEMP_LOG"
else
    echo "WARNING: no readable /sys/class/thermal/thermal_zone*/temp found -- temperature logging skipped." >&2
fi

cleanup() {
    if [ "$GOVERNOR_ENFORCED" -eq 1 ] && [ -n "$ORIGINAL_GOVERNOR" ]; then
        echo "$ORIGINAL_GOVERNOR" > "$GOVERNOR_FILE" 2>/dev/null || true
    fi
    if [ -n "$TEMP_LOGGER_PID" ]; then
        kill "$TEMP_LOGGER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

{
    echo "scaling_governor (as found): $ORIGINAL_GOVERNOR"
    echo "scaling_governor (enforced to 'performance' for this run): $([ "$GOVERNOR_ENFORCED" -eq 1 ] && echo yes || echo "NO -- see warning above")"
    if [ -r "$BOOST_FILE" ]; then
        echo "boost (acpi-cpufreq/amd_pstate generic toggle, 1=enabled): $(cat "$BOOST_FILE")"
    elif [ -r "$INTEL_NOTURBO_FILE" ]; then
        echo "no_turbo (intel_pstate, 1=turbo disabled): $(cat "$INTEL_NOTURBO_FILE")"
    else
        echo "boost/turbo state: not readable on this machine (checked acpi-cpufreq/amd_pstate boost and intel_pstate no_turbo)"
    fi
    echo "note: this script measures no latency/energy -- governor/temperature are logged for consistency, not because any result here depends on them"
} > "$CPU_STATE_LOG"
echo "CPU state logged to $CPU_STATE_LOG"

if [ ! -x "$EXPERIMENTS_DIR/seal/build/bench_seal" ]; then
    echo "ERROR: bench_seal not built yet (or stale). Run docker_build_and_run.sh first." >&2
    exit 1
fi

SCHEMES=("BFV" "CKKS" "BGV")

# Resume support (see run_standard_docker.sh) -- but this script's four
# operations don't share the reps+warmup=105-row schema the timed-op
# scripts use, so "expected row count" means something different per
# operation here:
#   size            always exactly 4 rows (ciphertext/public_key/secret_key/
#                   relin_keys) on success -- fixed.
#   config_metadata always exactly 1 row on success -- fixed.
#   ckks_error      CKKS: exactly trace_reps*(2+3*grid.depth) rows (this
#                   trace always uses grid.depth, never effective_depth --
#                   see bench_seal.cpp) -- computable directly from the grid
#                   row already in hand. BFV/BGV: always exactly 1 row (the
#                   skipped_not_applicable_bfv row).
#   noise_trace     CKKS: always exactly 1 row (skipped_not_applicable_ckks).
#                   BFV/BGV: trace_reps*(2+2*effective_depth) rows, and
#                   effective_depth is a noise-budget measurement that can
#                   come out above OR below grid.depth (see
#                   compute_effective_depth() in bench_seal.cpp) -- it isn't
#                   knowable from the grid alone without rerunning the
#                   probe. Instead of guessing, we read it back out of
#                   column 6 of an EXISTING file's own first data row: it's
#                   computed once and written identically to every row of a
#                   given file, so even a file truncated mid-write still
#                   carries the correct value. No existing file (or one with
#                   zero data rows) means there's nothing to read, which
#                   correctly falls through to "not done".
run_one() {
    local TAG="$1"; shift
    local EXPECTED_ROWS="$1"; shift
    local OUT_CSV_HOST="$RAW_DIR/${TAG}.csv"
    local OUT_CSV="/work/results/raw/extended_metrics/${TAG}.csv"

    if [ -f "$OUT_CSV_HOST" ] && [ "$(tail -n +2 "$OUT_CSV_HOST" | wc -l)" -ge "$EXPECTED_ROWS" ]; then
        echo "SKIPPED (already complete): ${TAG}.csv"
        return
    fi

    echo ">> $TAG"
    docker run --rm -v "$EXPERIMENTS_DIR":/work "$IMAGE" \
        /work/seal/build/bench_seal "$@" --out="$OUT_CSV" --grid="$GRID_CONTAINER" \
        || echo "   (non-zero exit — check $TAG)"
}

# --- Extra-rigor item 6: randomize order across (N,category,scheme,metric)
# -- flattened as a 4th "metric" field alongside the usual triple, since
# each of the four run_one() calls per scheme is its own independently-
# resumable unit (own tag, own EXPECTED_ROWS logic below), not a fixed
# sequence that has to stay together. See the adaptation note above for why
# this has no scientific effect here (kept for consistency, not necessity).
RUN_ORDER_SEED="${RUN_ORDER_SEED:-$RANDOM$RANDOM}"
echo "run_order_seed: $RUN_ORDER_SEED" >> "$CPU_STATE_LOG"
mapfile -t ALL_CELLS < <(
    tail -n +2 "$GRID_HOST" | while IFS=, read -r N CATEGORY SEC CHAIN LOGQ DEPTH; do
        for SCHEME in "${SCHEMES[@]}"; do
            for METRIC in size noise_trace ckks_error config_metadata; do
                echo "$N,$CATEGORY,$SCHEME,$METRIC,$DEPTH"
            done
        done
    done
)
mapfile -t SHUFFLED_CELLS < <(
    printf '%s\n' "${ALL_CELLS[@]}" | \
        shuf --random-source=<(openssl enc -aes-256-ctr -pass pass:"$RUN_ORDER_SEED" -nosalt </dev/zero 2>/dev/null)
)
echo "Run order randomized (seed=$RUN_ORDER_SEED, ${#SHUFFLED_CELLS[@]} cells) -- reproducible via RUN_ORDER_SEED=$RUN_ORDER_SEED"

# Durable record of the run-order seed: cpu_state.txt above lives under
# results/logs/, which is gitignored, so until now the seed actually used
# for any given run wasn't recoverable from anything that gets committed.
# Append one row per invocation to a small, git-tracked CSV instead.
RUN_METADATA_CSV="$EXPERIMENTS_DIR/results/run_metadata.csv"
if [ ! -f "$RUN_METADATA_CSV" ]; then
    echo "timestamp,scenario,run_order_seed,num_cells" > "$RUN_METADATA_CSV"
fi
echo "$(date -Iseconds),extended_metrics,$RUN_ORDER_SEED,${#SHUFFLED_CELLS[@]}" >> "$RUN_METADATA_CSV"

for CELL in "${SHUFFLED_CELLS[@]}"; do
    IFS=, read -r N CATEGORY SCHEME METRIC DEPTH <<< "$CELL"
    case "$METRIC" in
        size)
            run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_size" 4 \
                --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=size
            ;;
        noise_trace)
            NT_TAG="seal_${SCHEME,,}_N${N}_cat${CATEGORY}_noise_trace"
            if [ "$SCHEME" == "CKKS" ]; then
                NT_EXPECTED=1
            elif [ -f "$RAW_DIR/${NT_TAG}.csv" ] && [ "$(tail -n +2 "$RAW_DIR/${NT_TAG}.csv" | wc -l)" -gt 0 ]; then
                NT_EFFECTIVE_DEPTH=$(awk -F',' 'NR==2{print $6}' "$RAW_DIR/${NT_TAG}.csv")
                NT_EXPECTED=$((TRACE_REPS * (2 + 2 * NT_EFFECTIVE_DEPTH)))
            else
                NT_EXPECTED=1  # no existing data to read effective_depth from --
                                # any file with 0 data rows is correctly "not done"
                                # against this (or any positive) threshold.
            fi
            run_one "$NT_TAG" "$NT_EXPECTED" \
                --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=noise_trace \
                --trace-reps="$TRACE_REPS"
            ;;
        ckks_error)
            if [ "$SCHEME" == "CKKS" ]; then
                CE_EXPECTED=$((TRACE_REPS * (2 + 3 * DEPTH)))
            else
                CE_EXPECTED=1
            fi
            run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_ckks_error" "$CE_EXPECTED" \
                --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=ckks_error \
                --trace-reps="$TRACE_REPS"
            ;;
        config_metadata)
            run_one "seal_${SCHEME,,}_N${N}_cat${CATEGORY}_config_metadata" 1 \
                --scheme="$SCHEME" --N="$N" --category="$CATEGORY" --operation=config_metadata
            ;;
    esac
done

# ---- Consolidate the per-cell CSVs into three master raw files ----
# Simple concatenation (shared header once, then every cell's data rows),
# NOT statistics -- aggregate.py stays the only place stats get computed,
# per convention. The glob requires "_N*_cat*_" so it structurally cannot
# match the master output filenames themselves (seal_sizes.csv etc. have
# no "_N"/"_cat" segment) even on a re-run where they already exist.
consolidate() {
    local suffix="$1" outname="$2"
    local files=()
    while IFS= read -r -d '' f; do files+=("$f"); done < \
        <(find "$RAW_DIR" -maxdepth 1 -name "seal_*_N*_cat*_${suffix}.csv" -print0 | sort -z)

    if [ "${#files[@]}" -eq 0 ]; then
        echo "  WARNING: no per-cell files found for suffix '$suffix', skipping $outname" >&2
        return
    fi

    local first_header
    first_header=$(head -1 "${files[0]}")
    for f in "${files[@]}"; do
        if [ "$(head -1 "$f")" != "$first_header" ]; then
            echo "  ERROR: mismatched header in $f, aborting consolidation for $suffix" >&2
            return 1
        fi
    done

    { echo "$first_header"; for f in "${files[@]}"; do tail -n +2 "$f"; done; } > "$RAW_DIR/$outname"
    echo "  $outname: $(tail -n +2 "$RAW_DIR/$outname" | wc -l) data rows from ${#files[@]} files"
}

echo "-- Consolidating per-cell CSVs into master raw files --"
consolidate size seal_sizes.csv
consolidate noise_trace seal_noise_budget.csv
consolidate ckks_error seal_ckks_error.csv
consolidate config_metadata seal_config_metadata.csv

echo "Extended metrics sweep complete. Raw CSVs in $RAW_DIR."
echo "Next: aggregate.py support for these three schemas (not yet written)."
