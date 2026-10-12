#!/usr/bin/env bash
# monitor_estimator.sh — live view of a run_estimator_docker.sh run, refreshed
# every 5 s: CPU temperature, the estimator container's CPU and memory use,
# the configuration in progress and its elapsed time, configurations done.
# Usage (second terminal): bash monitor_estimator.sh      (Ctrl+C to quit)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/estimator_progress.log"
while true; do
    clear
    echo "=== Lattice Estimator — live monitor ($(date +%H:%M:%S)) ==="
    echo "CPU temperature : $(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 )) °C"
    ID=$(docker ps -q --filter ancestor=sagemath/sagemath@sha256:310dfe23fc786f3a5a06a7b0387c60201ec79b32c0db941b7624505ee5edb565 | head -1)
    if [ -n "$ID" ]; then
        docker stats --no-stream --format "Estimator       : {{.CPUPerc}} of one core, memory {{.MemUsage}}" "$ID"
    else
        echo "Estimator       : not running"
    fi
    if [ -f "$LOG" ]; then
        RUN=$(grep " RUN " "$LOG" | tail -1)
        TOTAL=$(echo "$RUN" | grep -o 'total=[0-9]*' | cut -d= -f2)
        SINCE=$(grep -n " RUN " "$LOG" | tail -1 | cut -d: -f1)
        DONE=$(tail -n +"$SINCE" "$LOG" | grep -c " DONE ")
        echo "Run             : ${RUN#* RUN }"
        echo "Progress        : $DONE / ${TOTAL:-?} configurations done"
        CUR=$(tail -n +"$SINCE" "$LOG" | grep " START " | tail -1)
        if [ -n "$CUR" ] && [ "$(tail -n +"$SINCE" "$LOG" | grep -c " START ")" -gt "$DONE" ]; then
            S=$(date -u -d "$(echo "$CUR" | cut -d' ' -f1)" +%s); E=$(( $(date -u +%s) - S )); [ $E -lt 0 ] && E=$((E + 86400))  # START times are UTC (container clock)
            echo "Now running     : ${CUR#* START } (for $((E / 60)) min $((E % 60)) s)"
        fi
        echo; echo "--- last results ---"
        tail -n +"$SINCE" "$LOG" | grep -E " DONE |wrote|rror" | tail -6
    else
        echo "No run started yet (no estimator_progress.log)."
    fi
    sleep 5
done
