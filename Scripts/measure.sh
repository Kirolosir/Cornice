#!/usr/bin/env bash
#
# Samples Cornice's own CPU and memory while it runs, so the figures quoted in
# the README are measured rather than estimated.
#
# Usage: ./Scripts/measure.sh [duration_seconds] [sample_interval_seconds]
#
# Run it with the panel collapsed and left alone — that is the state the app
# spends effectively all of its time in, and the only one where idle cost means
# anything.

set -euo pipefail

DURATION="${1:-120}"
INTERVAL="${2:-2}"

PID="$(pgrep -f "Cornice.app/Contents/MacOS/Cornice" | head -1 || true)"
if [ -z "$PID" ]; then
    echo "Cornice is not running. Start it with 'make run' first." >&2
    exit 1
fi

echo "Sampling pid $PID for ${DURATION}s every ${INTERVAL}s"
echo

SAMPLES=$(( DURATION / INTERVAL ))
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

for _ in $(seq 1 "$SAMPLES"); do
    # ps reports %cpu as a share of ONE core, so 100 means one core saturated.
    ps -o %cpu=,rss= -p "$PID" >> "$TMP" 2>/dev/null || break
    sleep "$INTERVAL"
done

awk '
{
    cpu += $1; rss += $2; n++
    if ($1 > maxcpu) maxcpu = $1
    if ($2 > maxrss) maxrss = $2
}
END {
    if (n == 0) { print "no samples collected"; exit 1 }
    printf "samples        %d\n", n
    printf "CPU  mean      %.2f%% of one core\n", cpu / n
    printf "CPU  peak      %.2f%%\n", maxcpu
    printf "RSS  mean      %.1f MB\n", (rss / n) / 1024
    printf "RSS  peak      %.1f MB\n", maxrss / 1024
}
' "$TMP"
