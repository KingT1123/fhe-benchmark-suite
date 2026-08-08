#!/usr/bin/env bash
# _inner_measure.sh — runs INSIDE the container (invoked by docker run).
#
# Runs bench_seal and measures its peak memory (RSS) by polling /proc, since
# the seal-env image doesn't have GNU `time` installed and we'd rather not
# require rebuilding the image just for that. Writes output in the same
# "Maximum resident set size (kbytes): N" format GNU time uses, so
# aggregate.py doesn't need to know the difference.
#
# Usage: _inner_measure.sh <bin_path> <mem_log_path> <bench_seal args...>

set -e
BIN="$1"; shift
MEM_LOG="$1"; shift

"$BIN" "$@" &
PID=$!
PEAK=0
while kill -0 "$PID" 2>/dev/null; do
    CUR=$(grep VmHWM /proc/"$PID"/status 2>/dev/null | awk '{print $2}')
    if [ -n "$CUR" ] && [ "$CUR" -gt "$PEAK" ]; then PEAK=$CUR; fi
    sleep 0.02
done
wait "$PID"
EXIT_CODE=$?
echo "Maximum resident set size (kbytes): $PEAK" > "$MEM_LOG"
exit $EXIT_CODE
