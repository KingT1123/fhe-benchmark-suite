# session_lib.sh — shared, FAIL-CLOSED machinery for the OpenFHE/SEAL
# measurement sessions (sourced by run_pilot_docker.sh and
# run_validation_session.sh; not run directly).
#
# Fail-closed rules:
#   * a cell (one bench_seal/bench_openfhe invocation) counts only if
#     scripts/validate_cell.py accepts its CSV and its correctness-check file
#     (row count, order, statuses, finite positive latencies, every
#     repetition "correct");
#   * resume: an existing cell is skipped only if it is valid; an invalid or
#     partial one is moved to <session>/invalid/<timestamp>/ (kept, never
#     deleted) and measured again;
#   * a failed invocation (non-zero exit: crash, wrong primes, failed
#     correctness check) or a cell that does not validate STOPS THE WHOLE
#     SESSION with a non-zero exit -- nothing runs after it; the run can be
#     resumed once the cause is understood.
#
# Thermal/frequency log (thermal_log.csv, every second, whole session): for
# the pinned core, the effective frequency measured by the hardware
# (cpufreq cpuinfo_avg_freq, from the APERF/MPERF counters) and the
# frequency requested by the driver (scaling_cur_freq); the CPU temperature
# (k10temp Tctl) and both fan speeds. AMD exposes no thermal-throttle
# counter; the indicator is the effective frequency against the maximum boost
# frequency (amd_pstate_max_freq, in cpu_state.txt) while the temperature is
# at its limit.
#
# Required before sourcing: EXP (experiments dir), SESSION_DIR (raw output
# dir), LOG_DIR (memory logs), TASKSET_CORE.

hwmon_by_name() {  # hwmon numbering changes between boots: find by driver name
    for h in /sys/class/hwmon/hwmon*; do [ "$(cat "$h/name" 2>/dev/null)" = "$1" ] && { echo "$h"; return; }; done
}

session_start() {  # $1 = scenario name for run_metadata.csv, $2 = seed
    mkdir -p "$SESSION_DIR/checks" "$SESSION_DIR/memory" "$LOG_DIR"
    GOV="/sys/devices/system/cpu/cpu${TASKSET_CORE}/cpufreq/scaling_governor"
    ORIG_GOV="$(cat "$GOV" 2>/dev/null || echo "")"
    GOV_OK=0
    if [ -n "$ORIG_GOV" ] && echo performance > "$GOV" 2>/dev/null; then GOV_OK=1; else
        echo "WARNING: could not set the governor (run with sudo) -- only logged." >&2; fi
    CPUF="/sys/devices/system/cpu/cpu${TASKSET_CORE}/cpufreq"
    K10="$(hwmon_by_name k10temp)"; ASUS="$(hwmon_by_name asus)"
    TEMP_SRC="${K10:+$K10/temp1_input}"; [ -z "$TEMP_SRC" ] && TEMP_SRC=/sys/class/thermal/thermal_zone0/temp
    echo "timestamp,core,effective_freq_khz,requested_freq_khz,temp_millic,cpu_fan_rpm,gpu_fan_rpm" > "$SESSION_DIR/thermal_log.csv"
    ( while true; do
          echo "$(date -Iseconds),$TASKSET_CORE,$(cat "$CPUF/cpuinfo_avg_freq" 2>/dev/null),$(cat "$CPUF/scaling_cur_freq" 2>/dev/null),$(cat "$TEMP_SRC" 2>/dev/null),$(cat "$ASUS/fan1_input" 2>/dev/null),$(cat "$ASUS/fan2_input" 2>/dev/null)" >> "$SESSION_DIR/thermal_log.csv"
          sleep 1
      done ) &
    THERMAL_PID=$!
    trap session_cleanup EXIT
    local G=(git -c safe.directory='*' -C "$EXP/..")
    {
        echo "date: $(date -Iseconds)"
        echo "scenario: $1"
        echo "protocol: fail-closed v2 (every cell validated; correctness checks for every library)"
        echo "scaling_governor (as found): $ORIG_GOV; enforced performance: $([ $GOV_OK -eq 1 ] && echo yes || echo NO)"
        echo "boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo 'not readable')"
        echo "max boost frequency (amd_pstate_max_freq, kHz): $(cat "$CPUF/amd_pstate_max_freq" 2>/dev/null || cat "$CPUF/cpuinfo_max_freq")"
        echo "taskset_core: $TASKSET_CORE"
        echo "run_order_seed: $2"
        echo "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)"
        echo "kernel: $(uname -r)"
        echo "code commit: $("${G[@]}" rev-parse HEAD 2>/dev/null || echo unknown); uncommitted changes in experiments/{openfhe,seal/src,scripts}: $("${G[@]}" status --porcelain -- experiments/openfhe experiments/seal/src experiments/scripts 2>/dev/null | wc -l)"
        echo "images: seal-env $(docker image inspect -f '{{.Id}}' seal-env) openfhe-env $(docker image inspect -f '{{.Id}}' openfhe-env)"
    } > "$SESSION_DIR/cpu_state.txt"
}

session_cleanup() {
    [ "${GOV_OK:-0}" -eq 1 ] && echo "$ORIG_GOV" > "$GOV" 2>/dev/null || true
    [ -n "${THERMAL_PID:-}" ] && kill "$THERMAL_PID" 2>/dev/null || true
}

temp_c() { awk '{printf "%.0f", $1/1000}' "$TEMP_SRC" 2>/dev/null || echo "?"; }

# cell_valid TAG ROWS WARMUP -> 0 if the cell's CSV and check file validate
cell_valid() {
    python3 "$EXP/scripts/validate_cell.py" "$SESSION_DIR/$1.csv" --rows "$2" --warmup "$3" \
        --check "$SESSION_DIR/checks/$1_check.csv" >/dev/null
}

# quarantine TAG: move every file of an invalid/partial cell aside (kept)
quarantine() {
    local q="$SESSION_DIR/invalid/$(date +%Y%m%dT%H%M%S)"
    mkdir -p "$q"
    for f in "$SESSION_DIR/$1".csv* "$SESSION_DIR/checks/$1"_check.csv* "$SESSION_DIR/memory/$1"_mem*.log; do
        [ -e "$f" ] && mv "$f" "$q/"
    done
    echo "   moved the invalid/partial files of $1 to ${q#$EXP/}"
}

# run_cell LIB TAG ROWS WARMUP ARGS... : resume-aware, fail-closed.
# LIB = seal | openfhe. ARGS are the harness arguments without --out/--check-out.
# With RUN_DIRECT=1 the harness is started directly under taskset, without
# _inner_measure.sh's /proc polling loop -- as run_energy_memory_docker.sh does
# for energy and memory cells, so no extra process draws power during a RAPL
# window (peak memory then comes from the harness's own --peak-rss-out).
run_cell() {
    local lib="$1" tag="$2" rows="$3" warmup="$4"; shift 4
    if [ -e "$SESSION_DIR/$tag.csv" ] || compgen -G "$SESSION_DIR/$tag.csv.*" >/dev/null; then
        if cell_valid "$tag" "$rows" "$warmup"; then echo "   SKIPPED (valid, already complete): $tag"; return 0; fi
        echo "   existing $tag is NOT valid: $(python3 "$EXP/scripts/validate_cell.py" "$SESSION_DIR/$tag.csv" --rows "$rows" --warmup "$warmup" --check "$SESSION_DIR/checks/${tag}_check.csv")"
        quarantine "$tag"
    fi
    local rel="${SESSION_DIR#$EXP/}" t_start
    [ -f "$SESSION_DIR/cell_times.csv" ] || echo "tag,start,end,exit_code" > "$SESSION_DIR/cell_times.csv"
    t_start="$(date -Iseconds)"
    local io=(--out="/work/$rel/$tag.csv" --check-out="/work/$rel/checks/${tag}_check.csv")
    local rc=0
    local launch=(bash /work/scripts/_inner_measure.sh) memlog=("/work/${LOG_DIR#$EXP/}/${tag}_mem.log")
    [ "${RUN_DIRECT:-0}" = 1 ] && { launch=(taskset -c "$TASKSET_CORE"); memlog=(); }
    if [ "$lib" = "openfhe" ]; then
        docker run --rm -e TASKSET_CORE="$TASKSET_CORE" -e LD_LIBRARY_PATH=/usr/local/lib "${DOCKER_EXTRA[@]}" \
            -v "$EXP":/work -w /work/openfhe openfhe-env \
            "${launch[@]}" /work/openfhe/build/bench_openfhe "${memlog[@]}" \
            "$@" "${io[@]}" --eligible=/work/openfhe/probe/eligible_v2.csv || rc=$?
    else
        docker run --rm -e TASKSET_CORE="$TASKSET_CORE" "${DOCKER_EXTRA[@]}" -v "$EXP":/work -w /work/seal seal-env \
            "${launch[@]}" /work/seal/build/bench_seal "${memlog[@]}" \
            "$@" "${io[@]}" --grid=/work/config/param_grid.csv || rc=$?
    fi
    echo "$tag,$t_start,$(date -Iseconds),$rc" >> "$SESSION_DIR/cell_times.csv"
    if [ "$rc" -ne 0 ]; then
        echo "STOPPED: $tag failed (exit code $rc). No further cell is run. Fix the cause, then re-run this script to resume." >&2
        quarantine "$tag"; exit 2
    fi
    if ! cell_valid "$tag" "$rows" "$warmup"; then
        echo "STOPPED: $tag does not validate: $(python3 "$EXP/scripts/validate_cell.py" "$SESSION_DIR/$tag.csv" --rows "$rows" --warmup "$warmup" --check "$SESSION_DIR/checks/${tag}_check.csv")" >&2
        quarantine "$tag"; exit 2
    fi
    [ -f "$LOG_DIR/${tag}_mem.log" ] && cp "$LOG_DIR/${tag}_mem.log" "$SESSION_DIR/memory/"
    return 0
}
