#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-snapshot.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-snapshot-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CALLS="$TMP_ROOT/gh-calls"
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the script's own jq program over API-shaped JSON with the real jq, which was not found"

# The fake gh serves a canned GraphQL response chosen by the PR number passed
# with -F n=<N>, and records one line per call.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
echo "$1 $2" >> "$FM_TEST_CALLS"
[ "$1 $2" = "api graphql" ] || { echo "unexpected gh call: $*" >&2; exit 91; }
n=
prev=
for a in "$@"; do
  case "$prev:$a" in -F:n=*) n=${a#n=} ;; esac
  prev=$a
done
HEAD=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
pr() { # state draft mergeable mergeState decision reviews rollup
  jq -n --arg st "$1" --arg d "$2" --arg m "$3" --arg ms "$4" --arg dec "$5" \
    --argjson rv "$6" --arg ro "$7" --arg h "$HEAD" --arg n "$n" \
    '{data:{repository:{pullRequest:{state:$st,isDraft:($d=="true"),mergeable:$m,
      mergeStateStatus:$ms,reviewDecision:(if $dec=="" then null else $dec end),
      headRefOid:$h,url:("https://github.com/o/r/pull/"+$n),
      latestReviews:{nodes:$rv},
      commits:{nodes:[{commit:{statusCheckRollup:(if $ro=="" then null else {state:$ro} end)}}]}}}}}'
}
case "$n" in
  1) pr OPEN false MERGEABLE CLEAN APPROVED '[{"state":"APPROVED","author":{"login":"alice"}}]' SUCCESS ;;
  2) pr OPEN true CONFLICTING DIRTY "" '[]' PENDING ;;
  3) pr OPEN false MERGEABLE BEHIND REVIEW_REQUIRED '[]' FAILURE ;;
  4) pr OPEN false MERGEABLE BLOCKED "" '[{"state":"APPROVED","author":{"login":"a"}},{"state":"CHANGES_REQUESTED","author":{"login":"b"}}]' "" ;;
  5) pr MERGED false UNKNOWN UNKNOWN APPROVED '[]' SUCCESS ;;
  6) pr OPEN false UNKNOWN UNKNOWN "" '[]' "" ;;
  7) echo '{"data":{"repository":{"pullRequest":null}}}' ;;
  8) echo "boom" >&2; exit 1 ;;
  9) pr OPEN false MERGEABLE UNSTABLE "" '[]' SUCCESS ;;
  *) exit 92 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

snap() {
  : > "$CALLS"
  FM_TEST_CALLS=$CALLS PATH="$FAKEBIN:$PATH" "$SCRIPT" "$@"
}

test_clean_approved() {
  local out
  out=$(snap o/r#1) || fail "clean PR exited non-zero"
  assert_equals "o/r#1 state=open draft=no sync=clean review=approved checks=pass reviewers=alice:approved head=c2eac54 url=https://github.com/o/r/pull/1" "$out" "clean approved line"
  pass "clean approved PR"
}

test_draft_conflict() {
  local out
  out=$(snap https://github.com/o/r/pull/2) || fail "conflict PR exited non-zero"
  assert_equals "o/r#2 state=open draft=yes sync=conflict review=none checks=pending head=c2eac54 url=https://github.com/o/r/pull/2" "$out" "draft conflict line"
  pass "draft conflicting PR via URL"
}

test_behind_review_required() {
  local out
  out=$(snap o/r#3) || fail "behind PR exited non-zero"
  assert_equals "o/r#3 state=open draft=no sync=behind review=pending checks=fail head=c2eac54 url=https://github.com/o/r/pull/3" "$out" "behind line"
  pass "behind PR with required review and failing checks"
}

test_changes_wins_without_decision() {
  local out
  out=$(snap o/r#4) || fail "blocked PR exited non-zero"
  assert_equals "o/r#4 state=open draft=no sync=blocked review=changes checks=none reviewers=a:approved,b:changes_requested head=c2eac54 url=https://github.com/o/r/pull/4" "$out" "changes line"
  pass "changes requested wins when reviewDecision is absent"
}

test_merged_is_terse() {
  local out
  out=$(snap o/r#5) || fail "merged PR exited non-zero"
  assert_equals "o/r#5 state=merged head=c2eac54 url=https://github.com/o/r/pull/5" "$out" "merged line"
  pass "merged PR prints state only"
}

test_unknown_and_unstable() {
  local out
  out=$(snap o/r#6 o/r#9) || fail "unknown/unstable exited non-zero"
  assert_contains "$out" "o/r#6 state=open draft=no sync=unknown review=none checks=none" "unknown sync"
  assert_contains "$out" "o/r#9 state=open draft=no sync=unstable" "unstable sync"
  pass "unknown and unstable sync"
}

test_errors_nonzero_and_continue() {
  local out rc=0
  out=$(snap o/r#7 o/r#8 garbage o/r#1) || rc=$?
  assert_equals 1 "$rc" "error exit code"
  assert_contains "$out" "o/r#7 error=not-found" "not found"
  assert_contains "$out" "o/r#8 error=lookup-failed" "lookup failed"
  assert_contains "$out" "garbage error=unrecognised-ref" "bad ref"
  assert_contains "$out" "o/r#1 state=open" "later PR still reported"
  assert_not_contains "$out" "{" "no JSON dumped"
  pass "errors are one-liners, exit non-zero, and do not stop later PRs"
}

test_one_call_per_pr() {
  snap o/r#1 o/r#2 o/r#3 >/dev/null || fail "multi-PR exited non-zero"
  assert_equals 3 "$(wc -l < "$CALLS" | tr -d ' ')" "gh calls"
  pass "exactly one gh call per PR"
}

test_help_and_usage() {
  local out rc=0
  out=$("$SCRIPT" --help) || fail "--help failed"
  assert_contains "$out" "Usage: fm-pr-snapshot.sh" "help text"
  "$SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "no-arg exit code"
  pass "help and usage"
}

fm_test_run test_clean_approved test_draft_conflict test_behind_review_required \
  test_changes_wins_without_decision test_merged_is_terse test_unknown_and_unstable \
  test_errors_nonzero_and_continue test_one_call_per_pr test_help_and_usage
