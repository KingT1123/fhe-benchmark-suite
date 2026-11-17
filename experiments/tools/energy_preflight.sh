#!/usr/bin/env bash
# energy_preflight.sh — run (with sudo) immediately before starting or
# resuming a session of the energy/memory campaign. It
#   * checks that the charger is plugged in;
#   * sets the platform power profile to "balanced", the profile of the
#     validation sessions and of the stage-1 checks (a restart of the laptop
#     returns it to "performance");
#   * waits 20 s (the terminal and desktop settle after the command is typed),
#     then checks over 10 seconds that no process uses more than 20% of a CPU, and
#     lists those that do (a background program adds its power to every
#     energy reading: campaign session day1, a browser tab at 100% of a core).
# Exit status 0 = ready; 1 = not ready (nothing is started).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
[ "$(cat /sys/class/power_supply/ADP0/online)" = 1 ] || { echo "NOT READY: plug in the charger" >&2; exit 1; }
P=/sys/firmware/acpi/platform_profile
[ "$(cat $P)" = balanced ] || { echo "power profile: $(cat $P) -> balanced"; echo balanced > $P; }
[ "$(cat $P)" = balanced ] || { echo "NOT READY: could not set the power profile to balanced" >&2; exit 1; }
echo "checking for 30 seconds that nothing else is running (do not touch the laptop)..."
sleep 20
BUSY="$(top -b -d 10 -n 2 -w 200 | awk '/^top -/{blk++} blk==2 && $1 ~ /^[0-9]+$/ && $9+0 > 20 && $12 != "top" {print "   " $12 " (pid " $1 ", user " $2 "): " $9 "% CPU"}')"
if [ -n "$BUSY" ]; then
    echo "NOT READY: these programs are using the processor; close them and run the command again:" >&2
    echo "$BUSY" >&2
    exit 1
fi
echo "READY: charger in, power profile balanced, no other program using the processor"
