#!/usr/bin/env bash
#
# tmux-session-order — reorder sessions up/down in the session list.
#
# tmux has no native concept of custom session ordering: choose-tree can only
# sort by name, time, or index, and its S-Up/S-Down swap keys act on windows,
# not sessions. This plugin encodes order into the session NAME by prefixing a
# zero-padded numeric token (e.g. "010|work"). With choose-tree sorted by name,
# the tokens drive the visual order. "Move up/down" swaps the tokens of two
# adjacent sessions via rename-session. A display format strips the token so you
# only ever see the real session name.
#
# Usage:
#   session-order.sh up        # move the attached session up one slot
#   session-order.sh down      # move the attached session down one slot
#   session-order.sh up   <s>  # move session <s> up
#   session-order.sh down <s>  # move session <s> down
#   session-order.sh normalize # (re)assign clean sequential tokens to all sessions
#
# NOTE: intentionally NOT using `set -e`. This script performs a lot of
# conditional arithmetic ( (( x > y )) etc.) which returns non-zero when the
# expression is false; under `set -e` that aborts the script mid-run. We use
# `set -uo pipefail` and guard the operations that actually matter.
set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration (overridable via tmux options, exported by the .tmux entry file
# into the environment as SESSION_ORDER_*).
# ----------------------------------------------------------------------------
SEP="${SESSION_ORDER_SEP:-|}"      # token/name separator. Must not appear in names.
STEP="${SESSION_ORDER_STEP:-10}"   # gap between tokens on normalize (room to insert).
PAD="${SESSION_ORDER_PAD:-3}"      # zero-pad width. 3 => supports up to 999 slots.

# Extended-regex of session BASE names to never tokenize/reorder. Pinned
# infrastructure sessions (e.g. agents targeted by `has-session -t "<name>"`)
# must keep their exact name. Matched against the token-stripped base name with
# anchored full-string semantics (we wrap as ^(...)$). Empty = ignore nothing.
IGNORE="${SESSION_ORDER_IGNORE:-}"

# tmux binary indirection. Tests set SESSION_ORDER_TMUX="tmux -L <socket>" so the
# script can never touch the user's default server by accident. In normal use
# this is just "tmux" and run-shell already runs us in the right server context.
TMUX_CMD="${SESSION_ORDER_TMUX:-tmux}"
tx() { ${TMUX_CMD} "$@"; }

# A session name "matches" our scheme when it starts with <PAD digits><SEP>.
token_re="^[0-9]{${PAD}}\\${SEP}"

# True if a session (given its full name) is pinned/ignored and must be left
# completely untouched.
is_ignored() {
  local base
  base="$(name_base "$1")"
  [[ -n $IGNORE ]] && [[ $base =~ ^(${IGNORE})$ ]]
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Print the token (numeric prefix) of a name, or empty if untokenized.
name_token() {
  local name="$1"
  if [[ $name =~ $token_re ]]; then
    printf '%s' "${name%%"$SEP"*}"
  fi
}

# Print the base (token-stripped) part of a name.
name_base() {
  local name="$1"
  if [[ $name =~ $token_re ]]; then
    printf '%s' "${name#*"$SEP"}"
  else
    printf '%s' "$name"
  fi
}

# Zero-pad a number to $PAD width.
pad() { printf "%0${PAD}d" "$1"; }

# Emit all session names, one per line, in current sorted (name) order.
# Mirrors choose-tree -O name so "up"/"down" match what the user sees.
list_sorted() {
  tx list-sessions -F '#{session_name}' 2>/dev/null | LC_ALL=C sort
}

# Resolve the target session: explicit arg, else the attached/current session.
resolve_target() {
  local arg="${1:-}"
  if [[ -n $arg ]]; then
    printf '%s' "$arg"
  else
    tx display-message -p '#{session_name}'
  fi
}

# Atomically swap the tokens of two existing sessions, using a unique temporary
# name to avoid collisions during the two-step rename.
swap_tokens() {
  local a="$1" b="$2"   # full current names
  local a_base b_base a_tok b_tok
  a_base="$(name_base "$a")"; a_tok="$(name_token "$a")"
  b_base="$(name_base "$b")"; b_tok="$(name_token "$b")"

  # Both must be tokenized for a pure swap; ensure_tokens guarantees this, but
  # guard anyway.
  if [[ -z $a_tok || -z $b_tok ]]; then
    return 1
  fi

  local tmp="__sesh_order_tmp_$$__"
  tx rename-session -t "$a" "$tmp"            || return 1
  tx rename-session -t "$b" "${a_tok}${SEP}${b_base}" || return 1
  tx rename-session -t "$tmp" "${b_tok}${SEP}${a_base}" || return 1
}

# Emit non-ignored session names in current sorted order. Ignored (pinned)
# sessions are excluded entirely so the reordering logic never sees or touches
# them. This is what every operation below iterates over.
list_orderable() {
  local n
  while IFS= read -r n; do
    is_ignored "$n" || printf '%s\n' "$n"
  done < <(list_sorted)
}

# Ensure every orderable session has a token. Untokenized sessions are appended
# after the current max token, preserving their existing sorted position
# relative to each other. Idempotent; safe to call before every move.
ensure_tokens() {
  local names=() n
  while IFS= read -r n; do names+=("$n"); done < <(list_orderable)
  (( ${#names[@]} == 0 )) && return 0

  # Current max token value (base-10; leading zeros are not octal).
  local maxtok=0 tok val
  for n in "${names[@]}"; do
    tok="$(name_token "$n")"
    if [[ -n $tok ]]; then
      val=$((10#$tok))
      if (( val > maxtok )); then maxtok=$val; fi
    fi
  done

  local next=$(( (maxtok / STEP + 1) * STEP ))
  for n in "${names[@]}"; do
    if [[ -z "$(name_token "$n")" ]]; then
      tx rename-session -t "$n" "$(pad "$next")${SEP}${n}"
      next=$((next + STEP))
    fi
  done
  return 0
}

# Reassign clean, evenly-spaced tokens to all orderable sessions in sorted order.
normalize() {
  ensure_tokens
  local names=() n
  while IFS= read -r n; do names+=("$n"); done < <(list_orderable)
  (( ${#names[@]} == 0 )) && return 0

  local i=1 val base want
  for n in "${names[@]}"; do
    val=$((i * STEP))
    base="$(name_base "$n")"
    want="$(pad "$val")${SEP}${base}"
    if [[ $n != "$want" ]]; then
      tx rename-session -t "$n" "$want"
    fi
    i=$((i + 1))
  done
  return 0
}

# Core move. dir = "up" (toward top of list) or "down".
move() {
  local dir="$1" target_raw="$2"

  local target_base
  target_base="$(name_base "$target_raw")"

  # Refuse to move a pinned session.
  if is_ignored "$target_raw"; then
    tx display-message "session-order: '${target_base}' is pinned (ignored); not moving"
    return 0
  fi

  ensure_tokens

  local names=() n
  while IFS= read -r n; do names+=("$n"); done < <(list_orderable)
  (( ${#names[@]} == 0 )) && return 0

  # Locate target by base name (its token may have just been assigned).
  local idx=-1 i target_full=""
  for i in "${!names[@]}"; do
    if [[ "$(name_base "${names[$i]}")" == "$target_base" ]]; then
      idx=$i; target_full="${names[$i]}"; break
    fi
  done

  if (( idx < 0 )); then
    tx display-message "session-order: target '${target_base}' not found"
    return 0
  fi

  local swap_idx
  if [[ $dir == up ]]; then
    swap_idx=$((idx - 1))
  else
    swap_idx=$((idx + 1))
  fi

  if (( swap_idx < 0 || swap_idx >= ${#names[@]} )); then
    local edge; [[ $dir == up ]] && edge=top || edge=bottom
    tx display-message "session-order: '${target_base}' already at ${edge}"
    return 0
  fi

  if swap_tokens "$target_full" "${names[$swap_idx]}"; then
    tx display-message "session-order: moved '${target_base}' ${dir}"
  else
    tx display-message "session-order: failed to move '${target_base}'"
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Entry
# ----------------------------------------------------------------------------
main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    up)        move up   "$(resolve_target "${1:-}")" ;;
    down)      move down "$(resolve_target "${1:-}")" ;;
    normalize) normalize ;;
    tokens)    ensure_tokens ;;  # hidden: tokenize without moving
    *)
      echo "usage: session-order.sh {up|down|normalize} [session]" >&2
      exit 2
      ;;
  esac
}

main "$@"
