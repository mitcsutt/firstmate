#!/usr/bin/env bash
# fm-captain-view.sh - rebuild state/captain-view.json, the projection of every
# open captain hold across this home and its registered local secondmate homes.
#
# Usage:
#   fm-captain-view.sh [--quiet] [--stdout] [--no-parent]
#
# bin/fm-captain-hold.sh refreshes this projection from its own exit path after
# every hold, answer, settle and reconcile, so this command is only the manual
# rebuild. A render-only surface (the Herdr Captain pane) reads the file and
# draws it; firstmate owns all of the logic here, and a surface answers through
# fm-inbox.sh answer, never by interpreting a card.
#
# The write is atomic (temp file plus rename in state/). Secondmate homes are
# read-only: each registered local home in data/secondmates.md is queried
# through `fm-captain-hold.sh holds` and nothing under it is written. A remote
# registration, or a home whose data directory is missing, is listed under
# homes[] with ok=false and a reason instead of being guessed. Run inside a
# secondmate home, the rebuild also refreshes its local parent's projection
# (`--no-parent` stops that), so a mate-side change reaches the main view.
#
# --stdout prints the JSON instead of writing the file; --quiet silences the
# one-line summary.
#
# THE CONTRACT (schema fm-captain-view.v1). A surface may rely on exactly this:
#   schema     "fm-captain-view.v1"
#   generated  UTC ISO-8601 time this projection was built
#   home       absolute path of the home that wrote the file
#   homes[]    {id, path, ok, holds, reason}; id is "(main)" or the mate id,
#              reason is null when ok
#   counts     {needs_you, waiting_on, dated, total} over cards[]
#   cards[]    one per open captain hold, ordered needs-you, waiting-on, dated,
#              each oldest first:
#     key          "<home_id>/<task>", unique across homes
#     task         the backlog task id; the keyed-answer intake's key
#     home_id      "(main)" or the owning secondmate id
#     home         absolute path of the owning home; an answer runs with
#                  FM_HOME set to it (fm-inbox.sh answer --home)
#     state        "needs-you", "waiting-on" or "dated"
#     waiting_on   who the hold waits on, or null
#     until        YYYY-MM-DD deferral date, or null
#     title        the task title
#     reason       the full hold reason
#     question     title + ": " + reason, the same text decisions_open carries
#     options[]    {label, recommended}; empty when the asker gave none
#     trail[]      "where this was" context lines, oldest first
#     origin       the originating task id, or null
#     asked        UTC timestamp the hold was set, or null
#     shown        UTC timestamp this card first appeared in this file, kept
#                  across rebuilds for the same hold
# Additive fields may appear; a surface must ignore what it does not know.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-captain-view: %s\n' "$*" >&2
  exit 1
}

quiet=0
to_stdout=0
no_parent=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet) quiet=1 ;;
    --stdout) to_stdout=1 ;;
    --no-parent) no_parent=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || fail "jq is required"

holds_for_home() {  # <home> <state> <data> <config>
  FM_HOME="$1" FM_STATE_OVERRIDE="$2" FM_DATA_OVERRIDE="$3" FM_CONFIG_OVERRIDE="$4" \
    "$SCRIPT_DIR/fm-captain-hold.sh" holds
}

home_id=$(fm_parent_channel_home_id "$FM_HOME" 2>/dev/null) || home_id='(main)'

entries=''
homes=''
add_home() {  # <id> <path> <state> <data> <config>
  local out rc=0 count reason
  out=$(holds_for_home "$2" "$3" "$4" "$5" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    count=$(printf '%s' "$out" | jq 'length')
    homes="$homes$(jq -nc --arg id "$1" --arg path "$2" --argjson holds "$count" \
      '{id:$id,path:$path,ok:true,holds:$holds,reason:null}')"$'\n'
    entries="$entries$(printf '%s' "$out" | jq -c --arg hid "$1" --arg home "$2" \
      '.[] | . + {home_id:$hid, home:$home}')"$'\n'
  else
    reason=$(printf '%s' "$out" | head -1)
    homes="$homes$(jq -nc --arg id "$1" --arg path "$2" --arg reason "${reason:-holds listing failed}" \
      '{id:$id,path:$path,ok:false,holds:0,reason:$reason}')"$'\n'
  fi
}

skip_home() {  # <id> <path> <reason>
  homes="$homes$(jq -nc --arg id "$1" --arg path "$2" --arg reason "$3" \
    '{id:$id,path:$path,ok:false,holds:0,reason:$reason}')"$'\n'
}

add_home "$home_id" "$FM_HOME" "$STATE" "$DATA" "$CONFIG"

registry="$DATA/secondmates.md"
if [ -f "$registry" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
      skip_home "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME" "remote home is not projected"
    elif [ ! -d "$SECONDMATE_REGISTRY_HOME/data" ]; then
      skip_home "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME" "home has no data directory"
    else
      add_home "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME" \
        "$SECONDMATE_REGISTRY_HOME/state" "$SECONDMATE_REGISTRY_HOME/data" "$SECONDMATE_REGISTRY_HOME/config"
    fi
  done < "$registry"
fi

target="$STATE/captain-view.json"
previous='{}'
if [ -f "$target" ] && [ ! -L "$target" ]; then
  previous=$(jq -c '.' "$target" 2>/dev/null) || previous='{}'
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
view=$(
  jq -n --arg now "$now" --arg home "$FM_HOME" --argjson previous "$previous" \
    --slurpfile homes <(printf '%s' "$homes") --slurpfile entries <(printf '%s' "$entries") '
    def rank: if .state == "needs-you" then 0 elif .state == "waiting-on" then 1 else 2 end;
    ([($previous.cards // [])[] | {key:(.key), value:{asked:.asked, shown:.shown}}] | from_entries) as $seen
    | ([$entries[] | . as $e
        | {key:($e.home_id + "/" + $e.id),
           task:$e.id, home_id:$e.home_id, home:$e.home,
           state:$e.state, waiting_on:$e.waiting_on, until:$e.until,
           title:$e.title, reason:$e.reason, question:($e.title + ": " + $e.reason),
           options:$e.options, trail:$e.trail, origin:$e.origin, asked:$e.asked}
        | . as $c
        | . + {shown:((($seen[$c.key] // null) as $p
                       | if $p != null and $p.asked == $c.asked and $p.shown != null then $p.shown else $now end))}]
       | sort_by([rank, (.asked // ""), .key])) as $cards
    | {schema:"fm-captain-view.v1", generated:$now, home:$home, homes:$homes,
       counts:{needs_you:([$cards[] | select(.state == "needs-you")] | length),
               waiting_on:([$cards[] | select(.state == "waiting-on")] | length),
               dated:([$cards[] | select(.state == "dated")] | length),
               total:($cards | length)},
       cards:$cards}'
) || fail "could not build the projection"

if [ "$to_stdout" = 1 ]; then
  printf '%s\n' "$view"
else
  mkdir -p -- "$STATE" || fail "cannot create $STATE"
  tmp=$(mktemp "$STATE/.captain-view.XXXXXX") || fail "cannot stage the projection in $STATE"
  trap 'rm -f -- "$tmp"' EXIT
  printf '%s\n' "$view" > "$tmp" || fail "cannot write the projection"
  mv -f -- "$tmp" "$target" || fail "cannot publish $target"
  trap - EXIT
  [ "$quiet" = 1 ] || printf 'captain-view: wrote %s (%s cards)\n' "$target" "$(printf '%s' "$view" | jq '.counts.total')"
fi

if [ "$no_parent" = 0 ] && [ "$home_id" != '(main)' ] && [ "$to_stdout" = 0 ] \
  && fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" \
  && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] && [ -n "$FM_SECONDMATE_PARENT_HOME" ] \
  && [ -d "$FM_SECONDMATE_PARENT_HOME/data" ]; then
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$FM_SECONDMATE_PARENT_HOME" \
    "$SCRIPT_DIR/fm-captain-view.sh" --quiet --no-parent >/dev/null 2>&1 || true
fi
