#!/usr/bin/env bash
# Print a one-line status snapshot per GitHub pull request, for a cheap check
# before telling anyone a PR is ready.
#
# Read-only: one `gh api graphql` query per PR, no per-check calls, no writes.
#
# Usage: fm-pr-snapshot.sh <pr-ref>...
#   A pr-ref is a full GitHub pull-request URL or owner/repo#N (github.com).
#   One line per PR, key=value tokens:
#     owner/repo#N state=open|merged|closed draft=yes|no
#       sync=clean|behind|conflict|blocked|unstable|unknown
#       review=approved|changes|pending|none checks=pass|fail|pending|none
#       [reviewers=login:state,...] head=<sha7> url=<url>
#   A merged or closed PR prints only state, head and url.
#   sync comes from mergeable and mergeStateStatus; review from reviewDecision,
#   falling back to each reviewer's latest review (changes requested wins);
#   checks from the head commit's status-check rollup.
#   A PR that cannot be read prints `owner/repo#N error=<reason>` and the
#   command exits 1 once every ref has been tried. Usage errors exit 2.
set -eu

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" | sed '$d'
}

die() {
  printf 'fm-pr-snapshot: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
  '') die "usage: fm-pr-snapshot.sh <pr-url|owner/repo#N>..." ;;
esac
command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

# shellcheck disable=SC2016
QUERY='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){
state isDraft mergeable mergeStateStatus reviewDecision headRefOid url
latestReviews(first:20){nodes{state author{login}}}
commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}'

# shellcheck disable=SC2016
JQ_PROGRAM='
def sync:
  if .mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY" then "conflict"
  elif .mergeStateStatus == "BEHIND" then "behind"
  elif .mergeStateStatus == "BLOCKED" then "blocked"
  elif .mergeStateStatus == "CLEAN" or .mergeStateStatus == "HAS_HOOKS" then "clean"
  elif .mergeStateStatus == "UNSTABLE" then "unstable"
  else "unknown" end;
def reviews: [(.latestReviews.nodes // [])[] | select(.state != "COMMENTED" and .state != "PENDING" and .state != "DISMISSED")];
def review:
  if .reviewDecision == "APPROVED" then "approved"
  elif .reviewDecision == "CHANGES_REQUESTED" then "changes"
  elif .reviewDecision == "REVIEW_REQUIRED" then "pending"
  elif (reviews | any(.state == "CHANGES_REQUESTED")) then "changes"
  elif (reviews | any(.state == "APPROVED")) then "approved"
  else "none" end;
def checks:
  (.commits.nodes[0].commit.statusCheckRollup.state // "") as $s
  | if $s == "SUCCESS" then "pass"
    elif $s == "FAILURE" or $s == "ERROR" then "fail"
    elif $s == "PENDING" or $s == "EXPECTED" then "pending"
    else "none" end;
def reviewers:
  reviews | map("\(.author.login // "?"):\(.state | ascii_downcase)") | .[0:5] | join(",");
(.headRefOid[0:7]) as $head
| (.state | ascii_downcase) as $state
| if $state != "open" then
    "state=\($state) head=\($head) url=\(.url)"
  else
    "state=open draft=\(if .isDraft then "yes" else "no" end) sync=\(sync) review=\(review) checks=\(checks)"
    + (reviewers | if . == "" then "" else " reviewers=\(.)" end)
    + " head=\($head) url=\(.url)"
  end'

status=0
for ref in "$@"; do
  owner='' repo='' number=''
  if [[ "$ref" =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/([1-9][0-9]*)/?$ ]] \
    || [[ "$ref" =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)#([1-9][0-9]*)$ ]]; then
    owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} number=${BASH_REMATCH[3]}
  else
    printf '%s error=unrecognised-ref\n' "$ref"
    status=1
    continue
  fi
  label="$owner/$repo#$number"
  if ! raw=$(gh api graphql -f query="$QUERY" -F o="$owner" -F r="$repo" -F n="$number" 2>/dev/null); then
    printf '%s error=lookup-failed\n' "$label"
    status=1
    continue
  fi
  if ! pr=$(printf '%s' "$raw" | jq -c '.data.repository.pullRequest // empty' 2>/dev/null) || [ -z "$pr" ]; then
    printf '%s error=not-found\n' "$label"
    status=1
    continue
  fi
  if ! line=$(printf '%s' "$pr" | jq -r "$JQ_PROGRAM" 2>/dev/null); then
    printf '%s error=unreadable-response\n' "$label"
    status=1
    continue
  fi
  printf '%s %s\n' "$label" "$line"
done
exit "$status"
