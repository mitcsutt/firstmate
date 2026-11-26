#!/usr/bin/env bash
# fm_parent_channel_clean_note folds a note onto one line capped at 1200 bytes,
# and keeps a trailing fm-input: segment intact when it has to cut.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-parent-channel-lib.sh"

filler() {  # <count>
  local out='' i=0
  while [ "$i" -lt "$1" ]; do out="${out}x"; i=$((i + 1)); done
  printf '%s' "$out"
}

test_short_note_is_only_folded() {
  local got
  got=$(fm_parent_channel_clean_note "$(printf 'a\tb\r\nc fm-input: yesno | rec=no')")
  [ "$got" = 'a b  c fm-input: yesno | rec=no' ] || fail "short note changed: $got"
  pass "a short note is only folded onto one line"
}

test_long_note_without_input_is_cut_at_the_cap() {
  local got
  got=$(fm_parent_channel_clean_note "$(filler 1500)")
  [ "${#got}" -eq 1200 ] || fail "plain long note is ${#got} bytes, not 1200"
  pass "a long note without an input line is cut at 1200"
}

test_long_note_keeps_its_trailing_input_segment() {
  local seg='fm-input: choice | a=Merge now | b=Wait | rec=a' got
  got=$(fm_parent_channel_clean_note "$(filler 1500)
$seg")
  [ "${#got}" -eq 1200 ] || fail "note is ${#got} bytes, not 1200"
  case "$got" in
    *" $seg") : ;;
    *) fail "trailing fm-input segment was not kept intact: ${got: -80}" ;;
  esac
  pass "a long note keeps its trailing fm-input segment intact"
}

test_input_segment_with_pipes_and_command_survives() {
  local seg='fm-input: command | cmd=gh auth status && echo ok | tee out' got
  got=$(fm_parent_channel_clean_note "$(filler 2000) $seg")
  case "$got" in
    *" $seg") : ;;
    *) fail "command segment was altered: ${got: -80}" ;;
  esac
  pass "an input segment carrying pipes and a command is kept verbatim"
}

test_oversized_input_segment_falls_back_to_the_plain_cut() {
  local got
  got=$(fm_parent_channel_clean_note "ask fm-input: text | note=$(filler 1500)")
  [ "${#got}" -eq 1200 ] || fail "oversized segment note is ${#got} bytes, not 1200"
  pass "an input segment that alone exceeds the cap falls back to the plain cut"
}

test_segment_filling_the_whole_cap_is_kept_alone() {
  local seg got
  seg="fm-input: text | note=$(filler 1200)"
  seg=${seg:0:1199}
  got=$(fm_parent_channel_clean_note "$(filler 300) $seg")
  [ "$got" = "$seg" ] || fail "a 1199-byte segment was not kept alone (${#got} bytes)"
  pass "a segment leaving no room for the head is kept alone"
}

fm_test_run \
  test_short_note_is_only_folded \
  test_long_note_without_input_is_cut_at_the_cap \
  test_long_note_keeps_its_trailing_input_segment \
  test_input_segment_with_pipes_and_command_survives \
  test_oversized_input_segment_falls_back_to_the_plain_cut \
  test_segment_filling_the_whole_cap_is_kept_alone
