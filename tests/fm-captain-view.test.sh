#!/usr/bin/env bash
# End-to-end tests for the captain-view projection (state/captain-view.json),
# the hold state and card detail recorded by fm-captain-hold.sh, their surfacing
# in the bearings snapshot, and the one-step surface answer fm-inbox.sh answer.
# Shared fixtures live in tests/captain-hold-helpers.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-view)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# shellcheck source=tests/captain-hold-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/captain-hold-helpers.sh"

run_view() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-view.sh" "$@"
}

run_inbox_answer() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-inbox.sh" answer "$@"
}

view_of() {  # <home>
  cat "$1/state/captain-view.json"
}

card_field() {  # <home> <key> <jq-expression over the card>
  view_of "$1" | jq -r --arg key "$2" ".cards[] | select(.key == \$key) | $3"
}

register_mate() {  # <main-home> <mate-id> <mate-home>
  mkdir -p "$3/data" "$3/state" "$3/config"
  printf '%s\n' "$2" > "$3/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$1" > "$3/.fm-secondmate-parent"
  printf -- '- %s - sample mate (home: %s; scope: sample scope; projects: sample; added 2026-11-01)\n' \
    "$2" "$3" >> "$1/data/secondmates.md"
}

test_hold_publishes_the_projection_with_state_and_card_detail() {
  local home
  home=$(make_home view-hold)
  run_captain "$home" hold pick-colour --title "Pick a colour" --reason "Which colour ships?" \
    --repo sample --option "Red" --option "Blue" --recommend 2 --trail "raised from review" >/dev/null \
    || fail "hold with card detail should succeed"
  [ -f "$home/state/captain-view.json" ] || fail "the hold itself must write state/captain-view.json"
  [ "$(view_of "$home" | jq -r .schema)" = fm-captain-view.v1 ] || fail "projection schema id"
  [ "$(card_field "$home" "(main)/pick-colour" .state)" = needs-you ] || fail "default state must be needs-you"
  [ "$(card_field "$home" "(main)/pick-colour" '.options | map(.label) | join(",")')" = "Red,Blue" ] \
    || fail "options must be carried in order"
  [ "$(card_field "$home" "(main)/pick-colour" '[.options[] | select(.recommended) | .label] | join(",")')" = Blue ] \
    || fail "the recommended flag must mark exactly the chosen option"
  [ "$(card_field "$home" "(main)/pick-colour" '.question')" = "Pick a colour: Which colour ships?" ] \
    || fail "question must be title plus reason"
  [ "$(card_field "$home" "(main)/pick-colour" '.trail[0]')" = "raised from review" ] || fail "trail carried"
  [ "$(card_field "$home" "(main)/pick-colour" '.home')" = "$home" ] || fail "card must name its home"
  [ "$(view_of "$home" | jq -r '.counts.needs_you')" = 1 ] || fail "counts.needs_you"
  pass "hold publishes the projection with state and card detail"
}

test_state_is_needs_you_waiting_on_or_dated() {
  local home
  home=$(make_home view-states)
  run_captain "$home" hold plain --title "Plain" --reason "decide" --repo sample >/dev/null || fail "plain hold"
  run_captain "$home" hold later --title "Later" --reason "revisit" --repo sample --until 2099-01-01 >/dev/null \
    || fail "dated hold"
  run_captain "$home" hold external --title "External" --reason "vendor reply" --repo sample \
    --waiting-on "Acme vendor" >/dev/null || fail "waiting-on hold"
  [ "$(card_field "$home" "(main)/plain" .state)" = needs-you ] || fail "plain hold is needs-you"
  [ "$(card_field "$home" "(main)/later" .state)" = dated ] || fail "future --until is dated"
  [ "$(card_field "$home" "(main)/later" .until)" = 2099-01-01 ] || fail "until carried"
  [ "$(card_field "$home" "(main)/external" .state)" = waiting-on ] || fail "waiting-on state"
  [ "$(card_field "$home" "(main)/external" .waiting_on)" = "Acme vendor" ] || fail "waiting_on owner"
  [ "$(view_of "$home" | jq -r '[.cards[].state] | join(",")')" = "needs-you,waiting-on,dated" ] \
    || fail "cards must order needs-you, waiting-on, dated"
  [ "$(view_of "$home" | jq -c '.counts')" = '{"needs_you":1,"waiting_on":1,"dated":1,"total":3}' ] \
    || fail "counts per state"
  pass "state is needs-you, waiting-on or dated"
}

test_rehold_keeps_replaces_and_clears_hold_state() {
  local home
  home=$(make_home view-rehold)
  run_captain "$home" hold ext --title "Ext" --reason "vendor" --repo sample --waiting-on "Acme" \
    --option "Wait" --option "Escalate" >/dev/null || fail "initial hold"
  run_captain "$home" hold ext --reason "vendor still silent" >/dev/null || fail "plain re-hold"
  [ "$(card_field "$home" "(main)/ext" .waiting_on)" = Acme ] || fail "a plain re-hold keeps the recorded state"
  [ "$(card_field "$home" "(main)/ext" '.options | length')" = 2 ] || fail "a plain re-hold keeps the options"
  run_captain "$home" hold ext --reason "vendor still silent" --option "Drop" >/dev/null || fail "option re-hold"
  [ "$(card_field "$home" "(main)/ext" '.options | map(.label) | join(",")')" = Drop ] \
    || fail "--option replaces just the options"
  [ "$(card_field "$home" "(main)/ext" .waiting_on)" = Acme ] || fail "options re-hold keeps waiting-on"
  run_captain "$home" hold ext --reason "vendor answered" --needs-you >/dev/null || fail "needs-you re-hold"
  [ "$(card_field "$home" "(main)/ext" .state)" = needs-you ] || fail "--needs-you clears waiting-on"
  pass "re-hold keeps, replaces and clears hold state"
}

test_new_hold_lifecycle_drops_a_stale_state() {
  local home decision
  home=$(make_home view-lifecycle)
  run_captain "$home" hold ext --title "Ext" --reason "vendor" --repo sample --waiting-on "Acme" >/dev/null \
    || fail "initial hold"
  decision="$home/decision.txt"
  printf 'lift it\n' > "$decision"
  run_captain "$home" answer ext --decision-file "$decision" --release >/dev/null || fail "release"
  [ "$(view_of "$home" | jq -r '.counts.total')" = 0 ] || fail "a released hold leaves the projection"
  run_captain "$home" hold ext --reason "ask again" >/dev/null || fail "re-hold after release"
  [ "$(card_field "$home" "(main)/ext" .state)" = needs-you ] || fail "a new lifecycle must not inherit waiting-on"
  pass "a new hold lifecycle drops a stale state"
}

test_hold_validates_state_and_option_flags() {
  local home
  home=$(make_home view-validate)
  run_captain "$home" hold a --title A --reason r --repo sample --waiting-on x --needs-you >/dev/null 2>&1 \
    && fail "--waiting-on with --needs-you must be refused"
  run_captain "$home" hold a --title A --reason r --repo sample --option one --recommend 2 >/dev/null 2>&1 \
    && fail "--recommend past the option count must be refused"
  run_captain "$home" hold a --title A --reason r --repo sample --recommend 1 >/dev/null 2>&1 \
    && fail "--recommend without options must be refused"
  run_captain "$home" hold a --title A --reason r --repo sample --option "two
lines" >/dev/null 2>&1 && fail "a multi-line option must be refused"
  [ ! -f "$home/data/a/captain-hold.json" ] || fail "a refused hold must record no state"
  pass "hold validates state and option flags"
}

test_answer_and_settle_remove_the_card() {
  local home decision
  home=$(make_home view-answer)
  run_captain "$home" hold one --title One --reason r --repo sample >/dev/null || fail "hold one"
  run_captain "$home" hold two --title Two --reason r --repo sample >/dev/null || fail "hold two"
  decision="$home/decision.txt"
  printf 'go\n' > "$decision"
  run_captain "$home" answer one --decision-file "$decision" >/dev/null || fail "answer"
  [ "$(view_of "$home" | jq -r '[.cards[].task] | join(",")')" = two ] || fail "answer removes only its card"
  printf 'two\tdone it\t\n' | run_captain "$home" answers --source "test board" >/dev/null || fail "keyed answers"
  [ "$(view_of "$home" | jq -r '.counts.total')" = 0 ] || fail "the keyed-answer intake refreshes the projection"
  pass "answer and keyed answers remove the card"
}

test_reconcile_note_refreshes_the_projection() {
  local home evidence
  home=$(make_home view-reconcile)
  run_captain "$home" hold chk --title Chk --reason r --repo sample >/dev/null || fail "hold"
  request_reconciles "$home" src-1 chk || fail "request reconcile"
  evidence="$home/note.txt"
  printf 'still waiting on the vendor\n' > "$evidence"
  run_captain "$home" reconcile note chk --note-file "$evidence" >/dev/null || fail "reconcile note"
  [ "$(card_field "$home" "(main)/chk" '.trail | map(select(startswith("reconciled: "))) | length')" = 1 ] \
    || fail "a reconcile note must appear in the card trail"
  printf 'moot now\n' > "$evidence"
  request_reconciles "$home" src-2 chk || fail "second reconcile request"
  run_captain "$home" reconcile close chk --evidence-file "$evidence" >/dev/null || fail "reconcile close"
  [ "$(view_of "$home" | jq -r '.counts.total')" = 0 ] || fail "reconcile close removes the card"
  pass "reconcile note and close refresh the projection"
}

test_manual_rebuild_is_atomic_and_keeps_shown() {
  local home before after leftovers
  home=$(make_home view-rebuild)
  run_captain "$home" hold keep --title Keep --reason r --repo sample >/dev/null || fail "hold"
  before=$(card_field "$home" "(main)/keep" .shown)
  [ -n "$before" ] && [ "$before" != null ] || fail "shown must be set"
  sleep 1
  run_view "$home" >/dev/null || fail "manual rebuild"
  after=$(card_field "$home" "(main)/keep" .shown)
  [ "$before" = "$after" ] || fail "shown must survive a rebuild of the same hold ($before vs $after)"
  leftovers=$(find "$home/state" -maxdepth 1 -name '.captain-view.*' | wc -l | tr -d ' ')
  [ "$leftovers" = 0 ] || fail "a rebuild must leave no temp files"
  [ "$(run_view "$home" --stdout | jq -r .schema)" = fm-captain-view.v1 ] || fail "--stdout prints the projection"
  pass "manual rebuild is atomic and keeps shown"
}

test_projection_reads_registered_secondmate_homes_read_only() {
  local main mate remote_line
  main=$(make_home view-main)
  mate="$TMP_ROOT/view-mate-home"
  mkdir -p "$mate"
  make_home view-mate-home >/dev/null
  register_mate "$main" ci-mate "$mate"
  remote_line='- far-mate - remote (host: other; root: /srv/fm; home: /srv/fm/home; scope: s; projects: p; added 2026-11-01)'
  printf '%s\n' "$remote_line" >> "$main/data/secondmates.md"
  run_captain "$mate" hold mate-call --title "Mate call" --reason "mate asks" --repo sample --waiting-on "Ritesh" \
    >/dev/null || fail "hold inside the secondmate home"
  before_state=$(find "$mate" -type f | sort | xargs cksum 2>/dev/null)
  run_captain "$main" hold main-call --title "Main call" --reason "main asks" --repo sample >/dev/null \
    || fail "main hold"
  [ "$(card_field "$main" "ci-mate/mate-call" .home)" = "$mate" ] || fail "the mate's card must name the mate home"
  [ "$(card_field "$main" "ci-mate/mate-call" .state)" = waiting-on ] || fail "the mate's waiting-on state is carried"
  [ "$(card_field "$main" "(main)/main-call" .home_id)" = "(main)" ] || fail "main card home_id"
  [ "$(view_of "$main" | jq -r '.homes[] | select(.id == "far-mate") | .ok')" = false ] \
    || fail "a remote home must be listed as not projected"
  [ "$(view_of "$main" | jq -r '.homes[] | select(.id == "ci-mate") | .holds')" = 1 ] || fail "mate hold count"
  after_state=$(find "$mate" -type f | sort | xargs cksum 2>/dev/null)
  [ -z "${before_state:-}" ] || [ "$before_state" = "$after_state" ] \
    || fail "building the main projection must not write under the mate home"
  pass "projection reads registered secondmate homes read-only"
}

test_a_mate_side_change_refreshes_the_parent_projection() {
  local main mate decision
  main=$(make_home view-parent)
  mate="$TMP_ROOT/view-parent-mate"
  make_home view-parent-mate >/dev/null
  register_mate "$main" it-mate "$mate"
  run_captain "$mate" hold from-mate --title "From mate" --reason "mate asks" --repo sample >/dev/null \
    || fail "mate hold"
  [ "$(card_field "$main" "it-mate/from-mate" .state)" = needs-you ] \
    || fail "a hold in a mate home must reach the parent's projection"
  decision="$mate/decision.txt"
  printf 'done\n' > "$decision"
  run_captain "$mate" answer from-mate --decision-file "$decision" >/dev/null || fail "mate answer"
  [ "$(view_of "$main" | jq -r '.counts.total')" = 0 ] || fail "a mate-side answer must clear the parent's card"
  pass "a mate-side change refreshes the parent projection"
}

test_bearings_decisions_open_rows_carry_state() {
  local home out
  home=$(make_home view-bearings)
  run_captain "$home" hold need --title Need --reason "you decide" --repo sample >/dev/null || fail "hold need"
  run_captain "$home" hold ext --title Ext --reason "vendor" --repo sample --waiting-on "Acme" >/dev/null \
    || fail "hold ext"
  out=$(run_bearings "$home") || fail "bearings snapshot"
  [ "$(printf '%s' "$out" | jq -r '.decisions_open[] | select(.id == "need") | .state')" = needs-you ] \
    || fail "an unmarked hold reads needs-you in decisions_open"
  [ "$(printf '%s' "$out" | jq -r '.decisions_open[] | select(.id == "ext") | .state')" = waiting-on ] \
    || fail "a waiting-on hold reads waiting-on in decisions_open"
  [ "$(printf '%s' "$out" | jq -r '.decisions_open[] | select(.id == "ext") | .waiting_on')" = Acme ] \
    || fail "decisions_open names who the hold waits on"
  pass "bearings decisions_open rows carry state"
}

test_inbox_answer_closes_the_hold_and_wakes_once() {
  local home out notes
  home=$(make_home view-inbox)
  run_captain "$home" hold ask --title Ask --reason "which?" --repo sample >/dev/null || fail "hold"
  out=$(run_inbox_answer "$home" --request-id surf-1 --source "Herdr captain pane" ask "Blue it is") \
    || fail "answer should succeed: $out"
  case "$out" in *"closed: ask"*) ;; *) fail "the intake outcome must be shown: $out" ;; esac
  [ "$(view_of "$home" | jq -r '.counts.total')" = 0 ] || fail "the answered card must leave the projection"
  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  [ "$notes" = 1 ] || fail "exactly one note must wake firstmate, got $notes"
  grep -q 'inbox:' "$home/state/.wake-queue" || fail "the answer must queue a wake"
  grep -q 'Blue it is' "$home"/state/inbox/*.note || fail "the note must carry the captain's words"
  pass "inbox answer closes the hold and wakes once"
}

test_inbox_answer_is_idempotent() {
  local home notes wakes
  home=$(make_home view-idem)
  run_captain "$home" hold ask --title Ask --reason "which?" --repo sample >/dev/null || fail "hold"
  run_inbox_answer "$home" --request-id surf-2 ask "same words" >/dev/null || fail "first answer"
  run_inbox_answer "$home" --request-id surf-2 ask "same words" >/dev/null || fail "an identical retry must succeed"
  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  [ "$notes" = 1 ] || fail "a retry must not create a second note, got $notes"
  wakes=$(grep -c 'inbox:' "$home/state/.wake-queue" || true)
  [ "$wakes" = 1 ] || fail "a retry must not queue a second wake, got $wakes"
  [ "$(grep -c 'Resolution mode' "$home/data/backlog.md" 2>/dev/null || true)" -le 1 ] \
    || fail "a retry must not record a second resolution"
  pass "inbox answer is idempotent"
}

test_inbox_answer_refusal_queues_nothing() {
  local home notes
  home=$(make_home view-refuse)
  run_inbox_answer "$home" --request-id surf-3 no-such-task "words" >/dev/null 2>&1 \
    && fail "an answer for a task that is not held must be refused"
  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
  [ "$notes" = 0 ] || fail "a refused answer must queue no note"
  run_inbox_answer "$home" ask "no request id" >/dev/null 2>&1 && fail "--request-id is required"
  run_inbox_answer "$home" --request-id surf-4 ask "  " >/dev/null 2>&1 && fail "an empty answer is refused"
  pass "inbox answer refusal queues nothing"
}

test_inbox_answer_reaches_a_secondmate_home_and_releases() {
  local main mate out
  main=$(make_home view-inbox-main)
  mate="$TMP_ROOT/view-inbox-mate"
  make_home view-inbox-mate >/dev/null
  register_mate "$main" ci-mate "$mate"
  run_captain "$mate" hold gate --title Gate --reason "approve the rollout?" --repo sample >/dev/null \
    || fail "mate hold"
  out=$(run_inbox_answer "$main" --request-id surf-5 --home "$mate" --release gate "approved, go ahead") \
    || fail "answer into the mate home: $out"
  [ "$(card_field "$main" "ci-mate/gate" .task)" = "" ] || fail "the released hold must leave the parent projection"
  [ "$(find "$main/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the note wakes the calling (main) home"
  [ "$(tasks_in "$mate" show gate --full | sed -n 's/^  held: //p')" = no ] || fail "--release lifts the hold"
  pass "inbox answer reaches a secondmate home and releases"
}

fm_test_run \
  test_hold_publishes_the_projection_with_state_and_card_detail \
  test_state_is_needs_you_waiting_on_or_dated \
  test_rehold_keeps_replaces_and_clears_hold_state \
  test_new_hold_lifecycle_drops_a_stale_state \
  test_hold_validates_state_and_option_flags \
  test_answer_and_settle_remove_the_card \
  test_reconcile_note_refreshes_the_projection \
  test_manual_rebuild_is_atomic_and_keeps_shown \
  test_projection_reads_registered_secondmate_homes_read_only \
  test_a_mate_side_change_refreshes_the_parent_projection \
  test_bearings_decisions_open_rows_carry_state \
  test_inbox_answer_closes_the_hold_and_wakes_once \
  test_inbox_answer_is_idempotent \
  test_inbox_answer_refusal_queues_nothing \
  test_inbox_answer_reaches_a_secondmate_home_and_releases
