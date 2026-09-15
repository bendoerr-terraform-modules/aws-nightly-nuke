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
# ⚠️ RETRIES: a single failed lookup is not evidence. Only a name that fails EVERY attempt
#   counts. The failure this guards is a service RETIREMENT, which is permanent; transient
#   lookup noise is not what we are hunting and must not red the board.
#
# ⚠️ SCOPE OF THE VERDICT, stated because the instrument is weaker than the word "dead" implies:
#   `getent hosts` reports DID-NOT-RESOLVE. It cannot distinguish NXDOMAIN from SERVFAIL, a
#   timeout, or a resolver refusal. We therefore say "does not resolve", never "NXDOMAIN".
#   The direction is false-RED (a sick resolver looks like a dead service), which is the safe
#   side AND the reason the positive control below is mandatory rather than decorative.
#   (Lilith's catch: the header claimed a discrimination the instrument does not make.)
#
# 🔴 BLOCK-WISE, NOT `sort -u` — AND THIS IS THE DEFECT THAT SHIPPED IN THE FIRST DRAFT.
#   The allowlist appears ONCE PER JOB (`no-dry-run` and `dry-run`). A first version parsed the
#   whole file and deduped: 328 endpoint lines collapsing to 164, exactly 2x. That reads CLEAN
#   whether the two blocks agree or not, so **a divergence between blocks was structurally
#   invisible to the very guard meant to police them** -- and the fix that prompted this script
#   was itself six lines across two blocks, which is precisely the shape that drifts.
#   Parsing per-block also SCOPES the match, so a service container or a URL-with-port added
#   elsewhere in the file can no longer manufacture a false DEAD. (Both Lilith's, both real:
#   the second was "uninfected, not correct" -- nothing else in the file matched *today*.)
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

# --- parse: each allowed-endpoints block SEPARATELY, so divergence is visible -----------
# awk: on `allowed-endpoints:` record that line's indent, then take following lines that are
# MORE indented; the first line at or below that indent ends the block. Emits "<n>\t<host>".
BLOCKS=$(mktemp) || { echo "NOT MEASURED - cannot create tempfile"; exit 2; }
trap 'rm -f "$BLOCKS"' EXIT   # SAFE HERE ONLY: this holds a parse of a public file and is
                              # cheap to regenerate, so DELETING is the cheap half. Do not
                              # copy this idiom over a run log, where KEEPING is the cheap half.
awk '
  match($0, /^[[:space:]]*allowed-endpoints:/) { blk++; ind=match($0,/[^ ]/); inblk=1; next }
  inblk {
    if ($0 ~ /^[[:space:]]*$/) next
    cur=match($0,/[^ ]/)
    if (cur <= ind) { inblk=0; next }
    if (match($0, /[A-Za-z0-9_.*-]+\.[A-Za-z]{2,}:[0-9]+/)) {
      h=substr($0, RSTART, RLENGTH); sub(/:[0-9]+$/, "", h); print blk "\t" h
    }
  }
' "$WF" > "$BLOCKS"

NBLOCKS=$(cut -f1 "$BLOCKS" | sort -u | grep -c . || true)
NLINES=$(grep -c . "$BLOCKS" || true)
[ "${NBLOCKS:-0}" -gt 0 ] || { echo "NOT MEASURED - found ZERO allowed-endpoints blocks in $WF; an empty population is not a pass"; exit 2; }

mapfile -t RAW < <(cut -f2 "$BLOCKS" | sort -u)
[ "${#RAW[@]}" -gt 0 ] || { echo "NOT MEASURED - parsed ZERO endpoints out of $WF; an empty population is not a pass"; exit 2; }

# 🔴 THE BLOCKS MUST AGREE. Compare them as SETS, pairwise against the first -- not by count,
# because two blocks can differ while having identical sizes (one swapped entry each way).
# 🔴🔴 DIVERGENCE IS RECORDED, NOT RETURNED ON. The first version of this block did
#   `exit 1` here, before the resolve loop -- so a file that was BOTH diverged AND carried a
#   dead name reported only the divergence, and the dead name was never scanned.
#   ⇒ **THE GUARD CONFESSED ONE SIN PER RUN: precisely the harden-runner behaviour it was
#   written to catch, rebuilt one level up, inside the fix.** Caught by Lilith with a
#   three-row table whose third row is the CONTROL -- a dead name planted in BOTH blocks
#   (no divergence) proves the name IS detectable, so its silence in the combined case is
#   the early exit and not a host that happens to resolve. Without that control the
#   combined row proves nothing.
#   `RAW` is the UNION across blocks, so the resolve scan is well-defined while diverged;
#   the early exit was a choice, never a necessity.
FIRST=$(cut -f1 "$BLOCKS" | sort -u | head -1)
DIVERGED=0
DIVREPORT=""
for b in $(cut -f1 "$BLOCKS" | sort -u); do
  [ "$b" = "$FIRST" ] && continue
  if ! diff -q <(awk -F'\t' -v k="$FIRST" '$1==k{print $2}' "$BLOCKS" | sort -u) \
                <(awk -F'\t' -v k="$b"     '$1==k{print $2}' "$BLOCKS" | sort -u) >/dev/null; then
    DIVERGED=1
    DIVREPORT="${DIVREPORT}DIVERGED - allowed-endpoints block $b does not match block $FIRST:
$(diff <(awk -F'\t' -v k="$FIRST" '$1==k{print $2}' "$BLOCKS" | sort -u) \
       <(awk -F'\t' -v k="$b"     '$1==k{print $2}' "$BLOCKS" | sort -u) | sed 's/^/    /')
"
  fi
done
if [ "$DIVERGED" -ne 0 ]; then
  echo "-- $NBLOCKS allowed-endpoints block(s) · $NLINES endpoint line(s) · ${#RAW[@]} distinct · blocks DIVERGE (scan continues over the UNION) --"
else
  echo "-- $NBLOCKS allowed-endpoints block(s) · $NLINES endpoint line(s) · ${#RAW[@]} distinct · blocks AGREE --"
fi

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

# --- report EVERY finding, then exit once. One run, all sins. ---------------------------
if [ "$DIVERGED" -ne 0 ]; then
  printf '%s' "$DIVREPORT"
  echo "  The jobs in this workflow are running under DIFFERENT egress policies. Whichever"
  echo "  block is missing an entry will have its agent abort and its egress silently revert."
fi
if [ "$DEAD" -gt 0 ]; then
  echo "DEAD - $DEAD allowlist entr(y/ies) DID NOT RESOLVE on any of $ATTEMPTS attempts:"
  printf '%s' "$DEADLIST"
  echo "  Each one of these ALONE disarms harden-runner's egress policy for the whole job,"
  echo "  silently, with the step still green. Remove them ALL in one change -- removing"
  echo "  only the one a log happened to name just reveals the next."
fi
if [ "$DIVERGED" -ne 0 ] || [ "$DEAD" -gt 0 ]; then
  echo "FOUND - divergence=$DIVERGED dead=$DEAD (both axes scanned; neither suppresses the other)"
  exit 1
fi
echo "CLEAN - all $LIVE resolvable-shaped allowlist entr(y/ies) resolve, and all $NBLOCKS block(s) agree."
exit 0
