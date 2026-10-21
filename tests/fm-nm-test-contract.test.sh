#!/usr/bin/env bash
# Contract: values parsed out of .no-mistakes.yaml must stay inside what
# no-mistakes accepts. commands.test must stay absent or empty, and
# review.chunk_threshold_lines must stay absent, 0, or greater than 500.
# The second matters because the daemon reads gate-control fields from the
# trusted default-branch copy and aborts every run in this repository when that
# copy fails validation (assertGateTrustedConfigReadable), so a value main
# cannot accept bricks the gate, including the run that would fix it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_review_chunk_threshold_passes_gate_validation() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
review = doc["review"] || {}
val = review.is_a?(Hash) ? review["chunk_threshold_lines"] : nil
lines = val.is_a?(Integer) ? val : nil
accepted = val.nil? || (!lines.nil? && (lines.zero? || lines > 500))
puts(accepted ? "" : val.inspect)
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "review.chunk_threshold_lines must be absent, 0 (disabled), or greater than 500, or the trusted-copy gate read rejects every run; got: $val"
  fi
  pass "no-mistakes review.chunk_threshold_lines passes trusted-copy validation"
}

test_nm_has_no_deterministic_test_command
test_nm_review_chunk_threshold_passes_gate_validation
