#!/usr/bin/env bash
#
# tmux-session-order — TPM entry point.
# Binds keys to move the current session up/down in the session list and exports
# user-tunable options into the reorder script's environment.
#
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CURRENT_DIR}/scripts/session-order.sh"

# Read a tmux option with a default. Works on older tmux that doesn't set an
# error code for missing options.
get_opt() {
  local opt="$1" default="$2" val
  val="$([[ -n $(tmux show-options -gqv "$opt") ]] \
      && tmux show-option -gqv "$opt" \
      || echo "$default")"
  echo "${val:-$default}"
}

# --- User options (with defaults) -------------------------------------------
KEY_UP="$(get_opt   "@session_order_key_up"   "S-Up")"     # prefix + Shift-Up
KEY_DOWN="$(get_opt "@session_order_key_down" "S-Down")"   # prefix + Shift-Down
KEY_NORMALIZE="$(get_opt "@session_order_key_normalize" "")" # unset by default
SEP="$(get_opt  "@session_order_sep"  "|")"
STEP="$(get_opt "@session_order_step" "10")"
PAD="$(get_opt  "@session_order_pad"  "3")"

# Export config so the script picks it up regardless of how it's invoked.
ENV_PREFIX="SESSION_ORDER_SEP='${SEP}' SESSION_ORDER_STEP='${STEP}' SESSION_ORDER_PAD='${PAD}'"

# --- Key bindings -----------------------------------------------------------
# Prefix-table bindings (outside choose-tree): move the ATTACHED session.
tmux bind-key "$KEY_UP" \
  run-shell "${ENV_PREFIX} '${SCRIPT}' up"
tmux bind-key "$KEY_DOWN" \
  run-shell "${ENV_PREFIX} '${SCRIPT}' down"

if [[ -n $KEY_NORMALIZE ]]; then
  tmux bind-key "$KEY_NORMALIZE" \
    run-shell "${ENV_PREFIX} '${SCRIPT}' normalize"
fi
