#!/usr/bin/env bash
# tests/fm-classify-outcome-tags.test.sh - optional "[pr=<url>]" and
# "[report=<path>]" tags at the head of a done/failed note
# (bin/fm-classify-lib.sh). Drives the real status_line_outcome_tag and
# status_line_note readers, so a tagged line neither loses its verb or time nor
# leaks the tags into the note.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

PR_URL=https://github.com/o/r/pull/7

assert_tag() {  # <line> <pr|report> <expected> <label>
  local got
  got=$(status_line_outcome_tag "$1" "$2") || got='<absent>'
  [ "$got" = "$3" ] || fail "$4: $2 tag got '$got' want '$3'"
}

assert_note() {  # <line> <expected> <label>
  local got
  got=$(status_line_note "$1")
  [ "$got" = "$2" ] || fail "$3: note got '$got' want '$2'"
}

test_tags_read_in_either_order_and_leave_the_note_clean() {
  local line="done [at=1788576000]: [pr=$PR_URL] [report=data/t/report.md] shipped it"
  assert_tag "$line" pr "$PR_URL" "pr first"
  assert_tag "$line" report data/t/report.md "pr first"
  assert_note "$line" "shipped it" "pr first"
  line="failed [at=1788576000]: [report=data/t/report.md] [pr=$PR_URL] gave up"
  assert_tag "$line" pr "$PR_URL" "report first"
  assert_tag "$line" report data/t/report.md "report first"
  assert_note "$line" "gave up" "report first"
  line="done: [pr=$PR_URL] only the pr"
  assert_tag "$line" report '<absent>' "pr only"
  assert_note "$line" "only the pr" "pr only"
  pass "outcome tags read in either order and are stripped from the note"
}

test_tags_follow_a_note_head_key() {
  local line="done [at=1788576000]: [key=ship] [pr=$PR_URL] landed"
  assert_tag "$line" pr "$PR_URL" "key then pr"
  assert_note "$line" "landed" "key then pr"
  pass "outcome tags are read after a note-head key"
}

test_untagged_and_other_verbs_are_untouched() {
  assert_tag "done: PR $PR_URL checks green" pr '<absent>' "plain ready line"
  assert_note "done [at=1788576000]: PR $PR_URL checks green" "PR $PR_URL checks green" "plain ready line"
  assert_tag "needs-decision [key=k]: [pr=$PR_URL] pick one" pr '<absent>' "other verb"
  assert_note "needs-decision [key=k]: [pr=$PR_URL] pick one" "[pr=$PR_URL] pick one" "other verb"
  pass "untagged lines and other verbs read exactly as before"
}

test_malformed_or_repeated_tags_stay_note_text() {
  assert_tag "done: [pr=not-a-url] x" pr '<absent>' "non-http pr"
  assert_note "done: [pr=not-a-url] x" "[pr=not-a-url] x" "non-http pr"
  assert_tag "done: [pr=$PR_URL] [pr=$PR_URL.2] x" pr "$PR_URL" "repeat keeps the first"
  assert_note "done: [pr=$PR_URL] [pr=$PR_URL.2] x" "[pr=$PR_URL.2] x" "repeat stays text"
  assert_tag "done: summary [pr=$PR_URL]" pr '<absent>' "tag deeper in the note"
  assert_note "done: summary [pr=$PR_URL]" "summary [pr=$PR_URL]" "tag deeper in the note"
  assert_tag "done: [report=a b] x" report '<absent>' "report with whitespace"
  pass "malformed, repeated, and misplaced tags are plain note text"
}

test_tags_do_not_move_verb_or_time() {
  local line="done [at=1788576000]: [pr=$PR_URL] shipped"
  [ "$(status_line_verb "$line")" = done ] || fail "tagged line lost its verb"
  [ "$(status_line_at_epoch "$line")" = 1788576000 ] || fail "tagged line lost its time"
  pass "outcome tags leave the verb and time readers unchanged"
}

test_tags_read_in_either_order_and_leave_the_note_clean
test_tags_follow_a_note_head_key
test_untagged_and_other_verbs_are_untouched
test_malformed_or_repeated_tags_stay_note_text
test_tags_do_not_move_verb_or_time
echo FM_TEST_COMPLETE
