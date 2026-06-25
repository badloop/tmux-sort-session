#!/usr/bin/env bash
# Isolated end-to-end test for tmux-sort-session.
# Forces a dedicated tmux socket so the real server is never touched.
set -uo pipefail

SOCKET="sesh-order-test-$$"
TXTEST="tmux -L ${SOCKET}"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/session-order.sh"

run() { SESSION_ORDER_TMUX="$TXTEST" SESSION_ORDER_SEP='|' SESSION_ORDER_STEP='10' SESSION_ORDER_PAD='3' "$SCRIPT" "$@"; }

# Visual order = sessions sorted by RAW name (choose-tree -O name sort key).
raw() { $TXTEST list-sessions -F '#{session_name}' | LC_ALL=C sort; }
# What the user SEES: raw-name order, then strip the token (do NOT re-sort).
display() { $TXTEST list-sessions -F '#{session_name}' | LC_ALL=C sort | sed -E 's/^[0-9]{3}\|//'; }

cleanup() { $TXTEST kill-server 2>/dev/null; }
trap cleanup EXIT

pass=0; fail=0
check() {
  if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; pass=$((pass+1))
  else echo "  FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"; fail=$((fail+1)); fi
}

$TXTEST kill-server 2>/dev/null
$TXTEST new-session -d -s "work"
$TXTEST new-session -d -s "mail"
$TXTEST new-session -d -s "music"
$TXTEST new-session -d -s "scratch"

echo "== Test 1: normalize assigns tokens, display strips them =="
run normalize
check "raw has tokens" "010|mail
020|music
030|scratch
040|work" "$(raw)"
check "display is clean" "mail
music
scratch
work" "$(display)"

echo "== Test 2: move 'music' up one (music 020 <-> mail 010) =="
run up music
check "raw order music first" "010|music
020|mail
030|scratch
040|work" "$(raw)"
check "display shows music above mail" "music
mail
scratch
work" "$(display)"

echo "== Test 3: idempotent re-tokenize changes nothing =="
before="$(raw)"; run tokens; after="$(raw)"
check "tokens idempotent" "$before" "$after"

echo "== Test 4: move down at bottom edge is a no-op =="
run down work
check "work still bottom" "010|music
020|mail
030|scratch
040|work" "$(raw)"

echo "== Test 5: move up at top edge is a no-op =="
run up music
check "music still top" "010|music
020|mail
030|scratch
040|work" "$(raw)"

echo "== Test 6: untokenized session created later gets appended =="
$TXTEST new-session -d -s "newbie"
run tokens
check "newbie appended last" "010|music
020|mail
030|scratch
040|work
050|newbie" "$(raw)"

echo "== Test 7: move down then up returns to original (round trip) =="
run down music   # music 010 <-> mail 020  => mail 010, music 020
run up music     # swap back
check "round trip restores" "010|music
020|mail
030|scratch
040|work
050|newbie" "$(raw)"

# ---------------------------------------------------------------------------
# Ignore-list (pinned sessions): infra sessions targeted by has-session -t
# "<name>" must NEVER be tokenized, and moves must skip over them.
# Use a SEPARATE socket to avoid kill/recreate races on the primary socket.
# ---------------------------------------------------------------------------
SOCKET2="sesh-order-test2-$$"
TX2="tmux -L ${SOCKET2}"
cleanup2() { $TX2 kill-server 2>/dev/null; }
trap 'cleanup; cleanup2' EXIT

IG='AGENT ONE|AGENT TWO'
run_ig() { SESSION_ORDER_TMUX="$TX2" SESSION_ORDER_SEP='|' SESSION_ORDER_STEP='10' SESSION_ORDER_PAD='3' SESSION_ORDER_IGNORE="$IG" "$SCRIPT" "$@"; }
raw2() { $TX2 list-sessions -F '#{session_name}' | LC_ALL=C sort; }

$TX2 kill-server 2>/dev/null
$TX2 new-session -d -s "AGENT ONE"
$TX2 new-session -d -s "AGENT TWO"
$TX2 new-session -d -s "alpha"
$TX2 new-session -d -s "beta"
$TX2 new-session -d -s "gamma"

echo "== Test 8: normalize tokenizes only NON-ignored sessions =="
run_ig normalize
check "pinned untouched, others tokenized" "010|alpha
020|beta
030|gamma
AGENT ONE
AGENT TWO" "$(raw2)"

echo "== Test 9: pinned session still findable by exact name (has-session) =="
if $TX2 has-session -t "AGENT ONE" 2>/dev/null; then
  check "has-session 'AGENT ONE' works" "ok" "ok"
else
  check "has-session 'AGENT ONE' works" "ok" "FAILED"
fi

echo "== Test 10: moving a pinned session is refused (no rename) =="
before="$(raw2)"
run_ig up "AGENT ONE"
check "pinned move is a no-op" "$before" "$(raw2)"

echo "== Test 11: moves operate only among orderable sessions =="
run_ig up gamma   # gamma 030 <-> beta 020
check "gamma rose above beta; pinned untouched" "010|alpha
020|gamma
030|beta
AGENT ONE
AGENT TWO" "$(raw2)"

echo ""
echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
