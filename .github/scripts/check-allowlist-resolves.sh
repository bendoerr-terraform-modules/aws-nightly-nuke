#!/usr/bin/env bash
# check-allowlist-resolves.sh [workflow-file]
#
# Does every host in harden-runner's `allowed-endpoints` still resolve?
#
# 0 = CLEAN     every resolvable-shaped entry resolved
# 1 = DEAD      at least one entry gives a consistent NXDOMAIN
# 2 = NOT MEASURED  the control failed, or the allowlist could not be parsed
#
# WHY THIS EXISTS (2026-09-15, measured on this repo, both directions).
#   harden-runner's agent pre-resolves every allowlisted domain at startup. If ONE name
#   does not resolve, the agent logs `Error resolving allowed domain`, prints
#   `Reverted changes`, and `agent.service` exits 1 -- and the harden-runner STEP STILL
#   REPORTS SUCCESS. So `egress-policy: block` is declared and NOT ENFORCED, on a green board.
#   Three separate failure signals, none of which reach the check surface.
#
# 🔴 AND IT ABORTS ON THE **FIRST** UNRESOLVABLE NAME, WHICH IS WHY THIS SCRIPT SCANS THE
#   WHOLE LIST RATHER THAN THE ONE IN THE LOG. Measured: run #2888 (10:43Z) died on
#   `robomaker`; run #2889 (15:57Z) died on `qldb`; a full sweep of all 164 entries found a
#   THIRD, `opsworks`, that no run has ever named. A guard that confesses one sin per run
#   makes "fixed the one in the log" structurally never "fixed them all" -- and each
#   sequential fix would have gone GREEN on its way to revealing the next.
#
# ⚠️ A POSITIVE CONTROL IS MANDATORY, NOT DECORATION. Without it a DNS outage on the runner
#   reads as "every domain is dead" -- a false RED that is believed precisely because it is
#   alarming. If the control cannot resolve, this exits 2 and asserts NOTHING about the list.
#
# ⚠️ RETRIES: a single NXDOMAIN is not evidence. Only a name that fails EVERY attempt counts.
#   The failure this guards is a service RETIREMENT, which is permanent; transient lookup
#   noise is not what we are hunting and must not red the board.
set -uo pipefail

WF="${1:-.github/workflows/aws-nuke.yml}"
CONTROL="${CONTROL_HOST:-dynamodb.us-east-1.amazonaws.com}"
ATTEMPTS="${ATTEMPTS:-3}"

[ -r "$WF" ] || { echo "NOT MEASURED - cannot read $WF"; exit 2; }

resolves() { # <host> -> 0 if ANY attempt resolves
  local h="$1" i
  for i in $(seq 1 "$ATTEMPTS"); do
    getent hosts "$h" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# --- CONTROL FIRST. An unresolvable control means the runner's DNS is the story. ---------
if ! resolves "$CONTROL"; then
  echo "NOT MEASURED - the positive control '$CONTROL' does not resolve from this runner."
  echo "  DNS here is broken or egress-filtered; a list scanned now would report every"
  echo "  entry dead. Refusing to emit a verdict about the allowlist."
  exit 2
fi

# --- parse: every `host:port` under an allowed-endpoints block --------------------------
mapfile -t RAW < <(grep -oE '[A-Za-z0-9_.*-]+\.[A-Za-z]{2,}:[0-9]+' "$WF" | sed 's/:[0-9]*$//' | sort -u)
[ "${#RAW[@]}" -gt 0 ] || { echo "NOT MEASURED - parsed ZERO endpoints out of $WF; an empty population is not a pass"; exit 2; }

LIVE=0; DEAD=0; WILD=0; DEADLIST=""
for h in "${RAW[@]}"; do
  case "$h" in
    \**) WILD=$((WILD+1)); continue ;;   # wildcards cannot be resolved; counted, not judged
  esac
  if resolves "$h"; then LIVE=$((LIVE+1)); else DEAD=$((DEAD+1)); DEADLIST="$DEADLIST  $h"$'\n'; fi
done

# print the denominator and assert the partition closes -- a count without one is a claim
TOTAL=$(( LIVE + DEAD + WILD ))
echo "-- ${#RAW[@]} parsed · $LIVE live · $DEAD dead · $WILD wildcard(skipped) · control '$CONTROL' OK --"
if [ "$TOTAL" -ne "${#RAW[@]}" ]; then
  echo "NOT MEASURED - partition does not close ($TOTAL != ${#RAW[@]}); the scan lost entries"
  exit 2
fi

if [ "$DEAD" -gt 0 ]; then
  echo "DEAD - $DEAD allowlist entr(y/ies) give a consistent NXDOMAIN over $ATTEMPTS attempts:"
  printf '%s' "$DEADLIST"
  echo "  Each one of these ALONE disarms harden-runner's egress policy for the whole job,"
  echo "  silently, with the step still green. Remove them ALL in one change -- removing"
  echo "  only the one a log happened to name just reveals the next."
  exit 1
fi
echo "CLEAN - all $LIVE resolvable-shaped allowlist entr(y/ies) resolve."
exit 0
