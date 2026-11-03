#!/usr/bin/env bash
#
# smoke.sh — end-to-end check against a **running** SplitJam.app.
#
# Why: the CLI talks to the app through a file mailbox. Wrong flags, wrong param names and bad
# ordering never show up at compile time — only here. This script walks
# doctor → ping → entitlement → project → track → beat → sections → chords → lyrics plus one
# error path, and fails loudly with the raw JSON whenever a step misbehaves.
#
# It never writes: every step is a read. A smoke test must be safe to run against someone's
# real project.
#
# Usage
#   ./scripts/smoke.sh                        # full read-only smoke
#   ./scripts/smoke.sh --project NAME         # pin a project instead of using the first one
#   ./scripts/smoke.sh --bridge-dir PATH      # point at another bridge (testing)
#   ./scripts/smoke.sh --verbose              # print the JSON received at every step
#
# Prerequisites: SplitJam is running and Settings → Command Line Access is on.
#
# Exit codes: 0 all passed / 1 some step failed / 3 app not reachable (doctor failed)
#
set -uo pipefail

BIN="${SPLITJAM:-splitjam}"
PROJECT=""
VERBOSE=0
STEP_TOTAL=0
STEP_FAILED=0
FAILED_NAMES=""
LAST_OUT=""

# Extra global flags forwarded to every call. An empty array in bash 3.2 expands to one empty
# argument, so it is only spliced in when it actually has entries.
GLOBAL=()

add_global() {
  GLOBAL[${#GLOBAL[@]}]="$1"
  if [ "$#" -gt 1 ]; then GLOBAL[${#GLOBAL[@]}]="$2"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?}"; shift 2 ;;
    --bridge-dir) add_global --bridge-dir "${2:?}"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "smoke.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null || { echo "smoke.sh: python3 is required" >&2; exit 2; }

# Run the CLI with the forwarded globals plus the given arguments.
sj() {
  if [ "${#GLOBAL[@]}" -gt 0 ]; then
    "$BIN" "${GLOBAL[@]}" "$@"
  else
    "$BIN" "$@"
  fi
}

pass() { STEP_TOTAL=$((STEP_TOTAL+1)); printf '  ok   %s\n' "$1"; }
fail() {
  STEP_TOTAL=$((STEP_TOTAL+1)); STEP_FAILED=$((STEP_FAILED+1))
  FAILED_NAMES="$FAILED_NAMES
  - $1"
  printf '  FAIL %s\n' "$1"
  [ -n "$LAST_OUT" ] && printf '%s\n' "$LAST_OUT" | sed 's/^/       /'
}

# run <name> <python-assertion> -- <cli args...>
# The python snippet gets the JSON on stdin and must exit non-zero when an assertion fails.
run() {
  local name="$1"; shift
  local check="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local out code
  out="$(sj --json "$@" 2>&1)"
  code=$?
  LAST_OUT="$out"
  [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$out" | sed 's/^/       /'
  if [ "$code" -ne 0 ]; then
    fail "$name (exit $code)"
    return 1
  fi
  if ! printf '%s' "$out" | python3 -c "$check" >/dev/null 2>&1; then
    fail "$name (unexpected payload)"
    return 1
  fi
  pass "$name"
}

echo "== splitjam smoke =="

# 1. Presence. Everything below is meaningless if the app is not reachable.
if ! sj doctor >/dev/null 2>&1; then
  echo "  FAIL doctor — SplitJam is not reachable."
  echo "       Open SplitJam and enable Settings → Command Line Access, then retry."
  exit 3
fi
pass "doctor"

run "ping" 'import json,sys; d=json.load(sys.stdin); assert d["ok"] and d["result"]["pong"]' -- ping
run "capabilities" 'import json,sys; d=json.load(sys.stdin); r=d["result"]; assert r.get("operations") or r.get("ops")' -- capabilities
run "schema" 'import json,sys; d=json.load(sys.stdin); assert d["ok"]' -- schema
run "entitlement" 'import json,sys; d=json.load(sys.stdin); assert d["ok"]; assert d["result"].get("tier") in ("pro","free","unknown")' -- entitlement get

# 2. Pick a project; the rest of the chain needs a concrete id.
if [ -z "$PROJECT" ]; then
  LIST="$(sj --json project list 2>&1)"
  PROJECT="$(printf '%s' "$LIST" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if not d.get("ok"):
    sys.exit(1)
projects=d["result"].get("projects") or []
if not projects:
    sys.exit(1)
print(projects[0].get("id") or "")
' 2>/dev/null)"
fi
if [ -z "$PROJECT" ]; then
  fail "project list (no project found)"
  echo
  echo "$STEP_FAILED of $STEP_TOTAL step(s) failed."
  exit 1
fi
pass "project list"
echo "       using project: $PROJECT"

run "project get"  'import json,sys; d=json.load(sys.stdin); assert d["ok"]; assert d.get("revision") or d["result"].get("revision")' -- project get --project "$PROJECT"
run "track list"   'import json,sys; d=json.load(sys.stdin); assert d["ok"]; assert isinstance(d["result"].get("tracks"), list)' -- track list --project "$PROJECT"
run "beat get"     'import json,sys; d=json.load(sys.stdin); assert d["ok"]; assert "grid" in d["result"] and "metronome" in d["result"]' -- beat get --project "$PROJECT"
run "section list" 'import json,sys; d=json.load(sys.stdin); assert d["ok"]' -- section list --project "$PROJECT"
run "chord get"    'import json,sys; d=json.load(sys.stdin); assert d["ok"]' -- chord get --project "$PROJECT"

# Lyrics may legitimately be absent: E_NOT_FOUND is a pass, anything else is a failure.
LYR_OUT="$(sj --json lyrics get --project "$PROJECT" 2>&1)"
if printf '%s' "$LYR_OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d.get("ok") or (d.get("error") or {}).get("code") == "E_NOT_FOUND"
' >/dev/null 2>&1; then
  pass "lyrics get (or absent)"
else
  LAST_OUT="$LYR_OUT"
  fail "lyrics get"
fi

# 3. One error path: a project reference that cannot resolve must be exit 4, not a crash.
sj --json project get "definitely-not-a-project-$RANDOM" >/dev/null 2>&1
ERR_CODE=$?
LAST_OUT=""
if [ "$ERR_CODE" -eq 4 ]; then
  pass "unknown project -> exit 4"
else
  fail "unknown project -> expected exit 4, got $ERR_CODE"
fi

echo
if [ "$STEP_FAILED" -eq 0 ]; then
  echo "all $STEP_TOTAL steps passed."
  exit 0
fi
echo "$STEP_FAILED of $STEP_TOTAL step(s) failed:$FAILED_NAMES"
exit 1
