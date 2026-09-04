#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode. fm-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id mode brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_mode in "brief-nomistakes-a1:no-mistakes" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_grep "learning-candidate-lifecycle/SKILL.md" "$brief" \
      "$id: brief missing the conditional learning-candidate lifecycle pointer"
    assert_grep "routine success adds nothing" "$brief" \
      "$id: brief turned learning capture into a routine completion audit"
    assert_grep "originating lane captures only" "$brief" \
      "$id: brief assigned asynchronous curation to the implementation lane"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
    assert_grep "at a detached HEAD on a clean copy of your task's base branch (its recorded landing branch, else the default branch)." "$brief" \
      "$id: ship brief does not describe its base as the recorded landing branch, else the default branch"
    assert_no_grep "at a detached HEAD on a clean default branch" "$brief" \
      "$id: ship brief still describes its base as the default branch unconditionally"
  done
  id='brief-scout-preamble-a1'
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "fm-brief.sh $id --scout should exit 0"
  brief="$home/data/$id/brief.md"
  assert_grep "at a detached HEAD on a clean default branch." "$brief" \
    "$id: scout brief lost its default-branch base wording although scouts take no landing branch"
  assert_no_grep "recorded landing branch" "$brief" \
    "$id: scout brief gained landing-branch wording although scouts take no landing branch"
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

learning_capture_command() {
  awk '
    $0 == "# Learning-candidate reminder" { section = 1; next }
    section && $0 == "```sh" { command = 1; next }
    command && $0 == "```" { exit }
    command { print }
  ' "$1"
}

test_learning_capture_command_binds_origin_home() {
  local intended ambient foreign project kind id brief command candidate rc json count
  intended="$TMP_ROOT/intended home's fleet"
  ambient="$TMP_ROOT/conflicting ambient home"
  foreign="$TMP_ROOT/foreign project worktree"
  project="confusing project's repo"
  mkdir -p "$intended/data" "$ambient/state" "$foreign/bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "printf 'wrong command executed\\n' >\"\$FM_CONFUSING_MARKER\"" \
    'exit 91' >"$foreign/bin/fm-learning-candidate.sh"
  chmod +x "$foreign/bin/fm-learning-candidate.sh"

  for kind in ship scout; do
    id="capture-$kind"
    if [ "$kind" = ship ]; then
      FM_HOME="$intended" "$ROOT/bin/fm-brief.sh" "$id" "$project" \
        --mode local-only >/dev/null 2>&1
    else
      FM_HOME="$intended" "$ROOT/bin/fm-brief.sh" "$id" "$project" \
        --scout >/dev/null 2>&1
    fi
    brief="$intended/data/$id/brief.md"
    command=$(learning_capture_command "$brief")
    [ -n "$command" ] || fail "$kind brief omitted its executable learning capture command"

    candidate=$(cd "$foreign" && \
      FM_HOME="$ambient" \
      FM_STATE_OVERRIDE="$ambient/state" \
      FM_ROOT_OVERRIDE="$ambient/stale-root" \
      FM_CONFUSING_MARKER="$foreign/local-command-ran" \
      FM_LEARNING_SIGNAL=review-rejection \
      FM_LEARNING_IMPACT="impact from $kind" \
      FM_LEARNING_ROOT_CAUSE="root cause from $kind" \
      FM_LEARNING_ESCAPED_CONTRACT="escaped contract from $kind" \
      FM_LEARNING_MISSING_CHECK="missing check from $kind" \
      FM_LEARNING_CONSUMER="consumer from $kind" \
      FM_LEARNING_PREVENTION="prevention from $kind" \
      FM_LEARNING_EVIDENCE="evidence from $kind" \
      FM_LEARNING_PROPOSED_OWNER="owner from $kind" \
      FM_LEARNING_COUNTERFACTUAL="counterfactual from $kind" \
      bash -c "$command" 2>"$intended/$id.err")
    rc=$?
    expect_code 0 "$rc" "$kind generated capture command failed: $(cat "$intended/$id.err")"
    case "$candidate" in lc-[0-9a-f][0-9a-f]*) ;; *) fail "$kind capture returned an invalid candidate id: $candidate" ;; esac
    assert_present "$intended/state/learning-candidates/$candidate.unresolved.json" \
      "$kind capture did not persist in the originating Firstmate home"
    json=$(FM_HOME="$intended" FM_STATE_OVERRIDE="$intended/state" \
      "$ROOT/bin/fm-learning-candidate.sh" get "$candidate")
    printf '%s\n' "$json" | jq -e --arg task "$id" --arg project "$project" '
      .incident.origin_task == $task and .incident.project == $project
    ' >/dev/null || fail "$kind generated capture lost its bound task or project: $json"
  done

  assert_absent "$ambient/state/learning-candidates" \
    "generated capture command wrote into the conflicting ambient home"
  assert_absent "$foreign/local-command-ran" \
    "generated capture command executed the foreign worktree's local namesake"
  count=$(find "$intended/state/learning-candidates" -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$count" -eq 2 ] || fail "generated ship/scout commands persisted $count candidates instead of two"
  pass "fm-brief.sh: ship and scout capture commands bind the originating home and tracked executable"
}

# A ship task's delivery mode is firstmate's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# no-mistakes-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||ship briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of no-mistakes, direct-PR, local-only
conditional policy is not a task mode|--mode no-mistakes-prod-only|classify this task's surface
ROWS
  pass "fm-brief.sh: ship --mode is required and closed-set validated"
}

# The registry is the captain's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a5 direct-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "explicit no-mistakes brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "explicit no-mistakes brief did not render the pipeline definition of done"

  # An unregistered project is not a blocker either, because nothing is looked up.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "fm-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is firstmate's approval authority and never reaches the worker, and a scout
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a scout brief|brief-refused-b3 some-proj --scout --mode direct-PR|--mode applies only to ship briefs
mode on a secondmate charter|brief-refused-b4 --secondmate --no-projects --mode no-mistakes|--mode applies only to ship briefs
ROWS
  pass "fm-brief.sh: --yolo and scout/secondmate --mode are refused, never silently dropped"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into that same recorded landing branch, or the default branch when none is recorded, through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_grep "Keep your branch a clean fast-forward onto your recorded landing branch - the \`landing_branch=\` firstmate recorded for this task in \`'$home/state/$id.meta'\` (contract: bin/fm-spawn.sh's header), falling back to the default branch only when none is recorded." "$brief" \
    "local-only brief does not keep the worker on its recorded landing branch"
  assert_no_grep "in \`state/$id.meta\`" "$brief" \
    "local-only brief still points the worker at a meta path relative to firstmate's home"
  assert_grep "If that landing branch has advanced, rebase onto it so the eventual merge stays a fast-forward." "$brief" \
    "local-only brief lost the landing-branch rebase instruction"
  assert_no_grep "if \`main\` has advanced, rebase onto it" "$brief" \
    "local-only brief still steers the worker back onto main"
  assert_no_grep "merges it into local \`main\`" "$brief" \
    "local-only brief still names local main as the merge target"
  assert_grep "firstmate handles the merge into your recorded landing branch (the default branch when none is recorded)." "$brief" \
    "local-only brief rule does not route the merge to the recorded landing branch"
  ! grep -i 'merg' "$brief" | grep -qF "\`main\`" \
    || fail "a local-only brief line still names main as the merge target: $(grep -i 'merg' "$brief" | grep -F "\`main\`")"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "make \`--intent\` preserve all relevant content from this brief" "$brief" \
    "no-mistakes DOD must require --intent to retain the accepted task contract"
  assert_grep "carrying only each requirement's current accepted form" "$brief" \
    "no-mistakes DOD must replace superseded requirements with their current accepted form"
  assert_grep "retain direct requirements instead of substituting a diff summary" "$brief" \
    "no-mistakes DOD must keep direct requirements and exclude generic scaffold boilerplate from --intent"
  assert_grep "exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific" "$brief" \
    "no-mistakes DOD must exclude non-task-specific scaffold boilerplate from --intent"
  # The apostrophe in "firstmate's authority check" is now structurally safe
  # (no `$(...)` wrapper around the heredoc), so it renders verbatim instead of
  # being reworded or escaped away. test_no_heredoc_in_command_substitution
  # guards the structure that makes it safe.
  assert_grep "firstmate's authority check" "$brief" \
    "no-mistakes DOD lost the apostrophe prose that the structural fix makes parse-safe"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'a blocker or wait clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
    assert_grep 'even when the answer is what started that work' "$brief" \
      "$kind brief did not warn that an answer-started done/working never closes a decision"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"
  assert_grep "you may host the Lavish review loop yourself" "$brief" \
    "scout brief must mention the option to host a Lavish review loop"
  assert_grep "learning-candidate-lifecycle/SKILL.md" "$brief" \
    "scout brief missing the conditional learning-candidate lifecycle pointer"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

# --- Playbot lane mode ------------------------------------------------------
# A lane's workspace is created by Playbot, which owns its branch and bases it on
# the landing branch's REMOTE tip. Firstmate used to countermand the scaffold's
# crewmate branch convention in the dispatch message and restate the delivery mode
# there; a brief that must be countermanded on delivery is a defect in the brief,
# and the override only works while firstmate remembers to send it. These tests pin
# the three things that had to move into the generated brief: the branch
# instructions, the base verification, and the prominent delivery contract.

# Every mode's lane brief must be free of the `fm/<task-id>` convention. It cannot
# be free of the string `git checkout -b`, because the brief now forbids that
# command by name - so this asserts the difference that matters: no instruction to
# create a branch, and no fm/<id> ref anywhere.
test_lane_mode_drops_the_crewmate_branch_convention() {
  local home id mode brief
  home="$TMP_ROOT/lane-branch-home"
  mkdir -p "$home/data"
  for mode in no-mistakes direct-PR local-only; do
    id="lane-drop-$mode"
    FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" --lane \
      --landing-branch proto/godot/frog-pile >/dev/null 2>&1 \
      || fail "$mode: --lane brief should scaffold"
    brief="$home/data/$id/brief.md"
    assert_no_grep "fm/$id" "$brief" \
      "$mode lane brief still names the crewmate fm/<task-id> branch"
    assert_no_grep "checkout -b fm/" "$brief" \
      "$mode lane brief still tells the lane to create an fm/ branch"
    assert_no_grep "First action: create your branch" "$brief" \
      "$mode lane brief still opens by creating a branch"
    assert_grep "Never run \`git checkout -b\` or \`git switch -c\`, and never switch branches" "$brief" \
      "$mode lane brief does not forbid creating or switching branches"
    assert_grep "Your workspace already owns its branch" "$brief" \
      "$mode lane brief does not state that the workspace owns the branch"
    assert_grep "Run \`git branch --show-current\` and verify it is" "$brief" \
      "$mode lane brief does not have the worker verify its branch before working"
    assert_grep "never create or switch branches" "$brief" \
      "$mode lane brief rule 1 does not carry branch ownership"
    # The safety contract a lane shares with every other ship brief must survive.
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$mode lane brief lost its machine-readable delivery contract line"
    assert_grep "**Verify isolation before anything else.**" "$brief" \
      "$mode lane brief lost the worktree-isolation assertion"
    assert_grep "{TASK}" "$brief" "$mode lane brief lost the {TASK} placeholder"
    assert_grep "Never stop, restart, or update the shared \`no-mistakes\` daemon" "$brief" \
      "$mode lane brief lost the shared-daemon rule"
    assert_grep "States: working, needs-decision, blocked, paused, done, failed." "$brief" \
      "$mode lane brief lost the status protocol"
  done
  pass "fm-brief.sh: lane mode drops the fm/<task-id> branch convention and keeps every safety rule"
}

# Playbot creates a lane workspace from the landing branch's REMOTE tip, so an
# unpushed local landing leaves the workspace stale. The brief must carry that
# check itself, with a deterministic action for each case, because a lane that
# silently builds on a stale base produces work against the wrong parent.
test_lane_brief_verifies_its_base_before_working() {
  local home brief
  home="$TMP_ROOT/lane-base-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" lane-base some-proj --mode no-mistakes --lane \
    --landing-branch proto/godot/frog-pile >/dev/null 2>&1 \
    || fail "lane brief with an explicit landing branch should scaffold"
  brief="$home/data/lane-base/brief.md"
  assert_grep "Playbot creates a lane workspace from the REMOTE tip of the landing branch" "$brief" \
    "lane brief does not explain why its base can start stale"
  assert_grep "Your landing branch is \`proto/godot/frog-pile\`, and every command below names it as \`refs/heads/proto/godot/frog-pile\`." "$brief" \
    "lane brief does not name the explicit landing branch it must verify against"
  # The comparison target is the LOCAL landing branch, fully qualified: Playbot
  # built the workspace from the remote tip, so origin/<landing> can never reveal an
  # unpushed landing, and a bare name resolves through refs/tags and refs/remotes.
  assert_grep "always spelled \`refs/heads/<landing branch>\`" "$brief" \
    "lane brief does not name the fully-qualified local landing branch as its comparison target"
  assert_no_grep "origin/proto/godot/frog-pile" "$brief" \
    "lane brief still compares its base against the remote ref it was created from"
  assert_grep "git rev-parse --verify --quiet refs/heads/proto/godot/frog-pile" "$brief" \
    "lane brief does not guard on the local landing branch existing as a branch ref"
  assert_grep "git rev-list --left-right --count refs/heads/proto/godot/frog-pile...HEAD" "$brief" \
    "lane brief does not read an explicit ahead/behind distance against the local landing branch"
  assert_no_grep "git log proto/godot/frog-pile..HEAD" "$brief" \
    "lane brief still infers its state from a bare-name single log range"
  assert_grep "prints anything that is NOT one of those eight paths: STOP and never reset" "$brief" \
    "lane brief resets a behind workspace without first requiring a clean working tree"
  assert_grep "Disclosure is a PRECONDITION of the reset" "$brief" \
    "lane brief does not make disclosure a precondition of discarding Playbot churn"
  assert_grep "Only then run \`git reset --hard refs/heads/proto/godot/frog-pile\` and proceed" "$brief" \
    "lane brief does not gate the reset behind its disclosure step"
  assert_grep "blocked: lane workspace is behind its landing branch but carries uncommitted changes" "$brief" \
    "lane brief does not stop and report a behind workspace that carries uncommitted work"
  assert_grep "ahead only: those commits are your own work, or the newer landing tip your workspace was created from" "$brief" \
    "lane brief does not let an ahead-only workspace proceed"
  assert_grep "proceed and do NOT reset" "$brief" \
    "lane brief does not forbid resetting an ahead-only workspace"
  assert_grep "blocked: lane workspace has diverged from its landing branch" "$brief" \
    "lane brief does not stop and report a diverged workspace"
  assert_no_grep "blocked: lane workspace carries commits of its own, so its base cannot be reset" "$brief" \
    "lane brief still blocks an ahead-only workspace with a commits-of-its-own reason"
  # The base check is part of the first action, before any task work.
  assert_grep "1. First action: verify your starting point before you touch anything." "$brief" \
    "lane brief does not make starting-point verification the first action"

  # A lane never goes through bin/fm-spawn.sh, so there is no state/<id>.meta to
  # read and no default branch to fall back to; --landing-branch is required
  # instead, so nothing in a lane brief may point at either.
  assert_no_grep "landing_branch=" "$brief" \
    "lane brief points at a state/<id>.meta field a Playbot lane never has"
  assert_no_grep "falling back to the default branch" "$brief" \
    "lane brief falls back to the default branch docs/playbot-lanes.md forbids for a lane"

  # local-only is where the landing branch decides the merge, so its definition of
  # done must use the same branch the base check verified against - and must not
  # send the lane to a state/<id>.meta or a default branch either.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" lane-base-dod some-proj --mode local-only --lane \
    --landing-branch proto/godot/frog-pile >/dev/null 2>&1 \
    || fail "local-only lane brief with an explicit landing branch should scaffold"
  brief="$home/data/lane-base-dod/brief.md"
  assert_grep "clean fast-forward onto your landing branch \`proto/godot/frog-pile\`" "$brief" \
    "local-only lane brief does not keep its branch a fast-forward onto the landing branch it was given"
  assert_grep "firstmate merges it into your landing branch \`proto/godot/frog-pile\` through the guarded fast-forward path" "$brief" \
    "local-only lane brief does not land on the landing branch it was given"
  assert_no_grep "landing_branch=" "$brief" \
    "local-only lane brief still reads a state/<id>.meta field a Playbot lane never has"
  assert_no_grep "falling back to the default branch" "$brief" \
    "local-only lane brief still falls back to the default branch"
  pass "fm-brief.sh: a lane brief verifies its base against the local landing branch before working"
}

# The whole point of the base check is the landing that firstmate merged locally
# and has not pushed: the workspace was created from the remote tip, so only the
# local branch can show the drift. These execute the procedure the generated brief
# prescribes - taking the landing ref out of the brief itself - against real
# repositories in each of the states a lane workspace can actually be in.
test_lane_base_check_detects_an_unpushed_landing() {
  local home brief lane_ref churn log status repo wt stale landed outcome own dirty
  home="$TMP_ROOT/lane-drift-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" lane-drift some-proj --mode local-only --lane \
    --lane-branch task/lane-drift --landing-branch landing/frog-pile >/dev/null 2>&1 \
    || fail "lane brief for the drift case should scaffold"
  brief="$home/data/lane-drift/brief.md"
  # shellcheck disable=SC2016  # the sed script matches the brief's literal backticks; nothing may expand here
  lane_ref=$(sed -n 's/^.*run `git reset --hard \([^`]*\)` and proceed.*$/\1/p' "$brief" | head -n 1)
  [ -n "$lane_ref" ] || fail "lane brief prescribes no ref to reset a stale base onto"
  churn=$(lane_brief_churn_pathspec "$brief")
  log="$TMP_ROOT/lane-drift.log"
  status="$TMP_ROOT/lane-drift.status"
  : > "$log"
  : > "$status"

  # Local landing branch at B, its origin ref still at the older A, lane worktree
  # checked out at A with no commits of its own - exactly the unpushed landing.
  repo="$TMP_ROOT/lane-drift-repo"
  wt="$TMP_ROOT/lane-drift-wt"
  fm_git_identity fmtest fmtest@example.invalid
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M landing/frog-pile
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" push -q origin landing/frog-pile
  stale=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" worktree add -q -b task/lane-drift "$wt" "$stale"
  printf 'landed\n' > "$repo/landed.txt"
  git -C "$repo" add landed.txt
  git -C "$repo" commit -qm "sibling lane landed locally, not pushed"
  landed=$(git -C "$repo" rev-parse landing/frog-pile)
  [ "$landed" != "$stale" ] || fail "drift fixture did not advance the local landing branch"
  [ "$(git -C "$wt" rev-parse "origin/landing/frog-pile")" = "$stale" ] \
    || fail "drift fixture pushed the landing commit, so the remote ref is not stale"

  # Behind with uncommitted work: reported with its paths, never reset.
  printf 'work in progress\n' > "$wt/wip.txt"
  git -C "$wt" add wip.txt
  outcome=$(lane_base_outcome "$wt" "$lane_ref" "$churn" "$log" "$status")
  [ "$outcome" = dirty ] \
    || fail "the prescribed base check reported '$outcome' for a behind workspace with uncommitted work, not a stop"
  dirty=$(lane_base_dirty_paths "$wt" "$churn")
  case "$dirty" in
    *wip.txt*) ;;
    *) fail "the prescribed dirty-tree report does not name the uncommitted path (got '$dirty')" ;;
  esac
  [ "$(git -C "$wt" rev-parse HEAD)" = "$stale" ] \
    || fail "the prescribed base check moved a dirty workspace's HEAD"
  [ -f "$wt/wip.txt" ] || fail "the prescribed base check discarded uncommitted lane work"

  # Behind with a clean tree: the drift is detected and the reset lands on B.
  git -C "$wt" rm -q -f wip.txt
  outcome=$(lane_base_outcome "$wt" "$lane_ref" "$churn" "$log" "$status")
  [ "$outcome" = reset ] \
    || fail "the base check the lane brief prescribes reported '$outcome' for an unpushed landing, not the drift"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$landed" ] \
    || fail "the prescribed reset did not move the lane worktree onto the local landing branch"

  # Ahead only: a second dispatch into an existing workspace, or a workspace built
  # from a newer remote tip, proceeds untouched rather than stopping.
  wt="$TMP_ROOT/lane-drift-ahead-wt"
  git -C "$repo" worktree add -q -b task/lane-drift-ahead "$wt" landing/frog-pile
  printf 'lane work\n' > "$wt/lane.txt"
  git -C "$wt" add lane.txt
  git -C "$wt" commit -qm "lane's own commit"
  own=$(git -C "$wt" rev-parse HEAD)
  outcome=$(lane_base_outcome "$wt" "$lane_ref" "$churn" "$log" "$status")
  [ "$outcome" = ahead ] \
    || fail "the prescribed base check reported '$outcome' for an ahead-only workspace, not a proceed"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$own" ] \
    || fail "the prescribed base check reset an ahead-only workspace"

  # Diverged: commits on both sides is the one commit-carrying state that stops.
  printf 'landed again\n' > "$repo/landed-2.txt"
  git -C "$repo" add landed-2.txt
  git -C "$repo" commit -qm "landing branch advanced again"
  outcome=$(lane_base_outcome "$wt" "$lane_ref" "$churn" "$log" "$status")
  [ "$outcome" = diverged ] \
    || fail "the prescribed base check reported '$outcome' for a diverged workspace, not a stop"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$own" ] \
    || fail "the prescribed base check moved a diverged workspace's HEAD"
  pass "fm-brief.sh: the lane base check resolves the four workspace states and never resets over work"
}

# A bare landing-branch name resolves through refs/tags/ and refs/remotes/ too, so
# a landing branch whose first component is also a remote name would silently
# compare against the remote tip the workspace was created from and report a stale
# base as current. The generated commands must be unsatisfiable by anything but a
# local branch.
test_lane_base_check_never_resolves_a_remote_or_tag_ref() {
  local home brief lane_ref churn repo wt outcome
  home="$TMP_ROOT/lane-qualified-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" lane-qualified some-proj --mode local-only --lane \
    --landing-branch proto/godot/frog-pile >/dev/null 2>&1 \
    || fail "lane brief for the ambiguous-ref case should scaffold"
  brief="$home/data/lane-qualified/brief.md"
  # shellcheck disable=SC2016  # the sed script matches the brief's literal backticks; nothing may expand here
  lane_ref=$(sed -n 's/^.*run `git reset --hard \([^`]*\)` and proceed.*$/\1/p' "$brief" | head -n 1)
  [ -n "$lane_ref" ] || fail "lane brief prescribes no landing ref"
  churn=$(lane_brief_churn_pathspec "$brief")

  # A remote literally named `proto` plus a tag of the same name: nothing but a
  # local branch `proto/godot/frog-pile` may satisfy the check, and there is none.
  repo="$TMP_ROOT/lane-qualified-repo"
  wt="$TMP_ROOT/lane-qualified-wt"
  fm_git_identity fmtest fmtest@example.invalid
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" remote rename origin proto
  git -C "$repo" push -q proto HEAD:refs/heads/godot/frog-pile
  git -C "$repo" fetch -q proto
  git -C "$repo" tag "proto/godot/frog-pile"
  git -C "$repo" worktree add -q -b task/lane-qualified "$wt" HEAD
  [ -n "$(git -C "$wt" rev-parse --verify --quiet 'proto/godot/frog-pile')" ] \
    || fail "fixture does not reproduce a bare name that resolves without a local branch"

  outcome=$(lane_base_outcome "$wt" "$lane_ref" "$churn" "$TMP_ROOT/lane-qualified.log" "$TMP_ROOT/lane-qualified.status")
  [ "$outcome" = missing ] \
    || fail "the prescribed base check reported '$outcome' against a remote-tracking or tag ref instead of stopping for a missing local landing branch"
  pass "fm-brief.sh: the lane base check refuses to resolve its landing branch to a tag or remote ref"
}

# The generated base check, run against a real worktree: a landing ref that is not
# a local branch stops, then one explicit ahead/behind reading selects among
# current, behind-only, ahead-only and diverged. Behind-only resets only when
# nothing outside the brief's eight Playbot churn paths is modified, and only after
# the disclosure the brief makes a precondition: capture the churn diff into the
# lane's log, then append one status line naming what is discarded.
# Echoes which outcome fired; performs the reset only in the arm that prescribes it.
lane_base_outcome() {
  local wt=$1 ref=$2 churn=$3 log=$4 status=$5 counts behind ahead dirty
  if [ -z "$(git -C "$wt" rev-parse --verify --quiet "$ref" 2>/dev/null)" ]; then
    printf 'missing\n'
    return 0
  fi
  counts=$(git -C "$wt" rev-list --left-right --count "$ref...HEAD") \
    || { printf 'unreadable\n'; return 0; }
  # shellcheck disable=SC2086  # the count output is two whitespace-separated fields
  set -- $counts
  behind=$1
  ahead=$2
  if [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then
    printf 'current\n'
    return 0
  fi
  if [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
    printf 'diverged\n'
    return 0
  fi
  if [ "$ahead" -gt 0 ]; then
    printf 'ahead\n'
    return 0
  fi
  if [ -n "$(lane_base_dirty_paths "$wt" "$churn")" ]; then
    printf 'dirty\n'
    return 0
  fi
  dirty=$(lane_base_churn_paths "$wt" "$churn")
  if [ -n "$dirty" ]; then
    # shellcheck disable=SC2086  # the brief's diff pathspec is a literal path list
    git -C "$wt" diff -- $churn >> "$log" 2>/dev/null || true
    printf 'working: discarding Playbot churn before base reset: %s\n' \
      "$(printf '%s' "$dirty" | tr '\n' ' ')" >> "$status"
  fi
  git -C "$wt" reset --hard "$ref" >/dev/null 2>&1 || { printf 'reset-failed\n'; return 0; }
  printf 'reset\n'
}

# The paths the brief's dirty-tree arm reports in its blocked line: everything
# git status prints that is not one of the eight literal churn paths.
lane_base_dirty_paths() {
  local wt=$1 churn=$2 line path
  git -C "$wt" status --porcelain | while IFS= read -r line; do
    path=${line#???}
    case " $churn " in
      *" $path "*) continue ;;
    esac
    printf '%s\n' "$path"
  done
}

# The churn paths the reset would discard, which the brief has the worker disclose.
lane_base_churn_paths() {
  local wt=$1 churn=$2 line path
  git -C "$wt" status --porcelain | while IFS= read -r line; do
    path=${line#???}
    case " $churn " in
      *" $path "*) printf '%s\n' "$path" ;;
    esac
  done
}

# The eight literal Playbot churn paths come out of the generated brief itself, so
# these tests execute the allowlist the brief actually prescribes.
lane_brief_churn_pathspec() {
  # shellcheck disable=SC2016  # the sed script matches the brief's literal backticks
  sed -n 's/^.*Before you reset, run `git diff -- \([^`]*\)`.*$/\1/p' "$1" | head -n 1
}

# Playbot's editor integration rewrites eight tracked paths across unrelated
# worktrees, so a lane workspace carrying only those is in its documented steady
# state and must still be resettable - but nothing may vanish unseen, so the brief
# makes capturing their diff and naming them a precondition of the reset.
test_lane_base_check_discloses_before_resetting_playbot_churn() {
  local home brief lane_ref churn repo wt log status stale landed outcome dirty
  home="$TMP_ROOT/lane-churn-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" lane-churn some-proj --mode local-only --lane \
    --lane-branch task/lane-churn --landing-branch landing/frog-pile >/dev/null 2>&1 \
    || fail "lane brief for the churn case should scaffold"
  brief="$home/data/lane-churn/brief.md"
  # shellcheck disable=SC2016  # the sed script matches the brief's literal backticks
  lane_ref=$(sed -n 's/^.*run `git reset --hard \([^`]*\)` and proceed.*$/\1/p' "$brief" | head -n 1)
  churn=$(lane_brief_churn_pathspec "$brief")
  [ -n "$churn" ] || fail "lane brief prescribes no churn pathspec to disclose"
  [ "$(printf '%s\n' "$churn" | wc -w | tr -d ' ')" = 8 ] \
    || fail "lane brief's churn pathspec is not the eight literal paths: $churn"
  case "$churn" in
    *prototype-game/project.godot*) ;;
    *) fail "lane brief's churn pathspec omits prototype-game/project.godot" ;;
  esac

  repo="$TMP_ROOT/lane-churn-repo"
  fm_git_identity fmtest fmtest@example.invalid
  fm_git_init_commit "$repo"
  mkdir -p "$repo/prototype-game/addons/playbot"
  printf 'config_version=5\n' > "$repo/prototype-game/project.godot"
  printf 'uid://original\n' > "$repo/prototype-game/addons/playbot/plugin.gd.uid"
  printf 'game code\n' > "$repo/app.txt"
  git -C "$repo" add prototype-game app.txt
  git -C "$repo" commit -qm "playbot addon plus game code"
  git -C "$repo" branch -M landing/frog-pile
  stale=$(git -C "$repo" rev-parse HEAD)
  printf 'landed\n' > "$repo/landed.txt"
  git -C "$repo" add landed.txt
  git -C "$repo" commit -qm "landed locally, not pushed"
  landed=$(git -C "$repo" rev-parse landing/frog-pile)

  # Behind, with only allowlisted churn modified: the reset proceeds, but the diff
  # is captured and the discarded paths named first.
  wt="$TMP_ROOT/lane-churn-wt"
  log="$TMP_ROOT/lane-churn.log"
  status="$TMP_ROOT/lane-churn.status"
  : > "$log"
  : > "$status"
  git -C "$repo" worktree add -q -b task/lane-churn "$wt" "$stale"
  printf 'config_version=5\nfolder_colors={"res://scenes":"red"}\n' > "$wt/prototype-game/project.godot"
  printf 'uid://rewritten\n' > "$wt/prototype-game/addons/playbot/plugin.gd.uid"
  outcome=$(lane_base_outcome "$wt" "$lane_ref" "$churn" "$log" "$status")
  [ "$outcome" = reset ] \
    || fail "the prescribed base check reported '$outcome' for a workspace carrying only Playbot churn, not a reset"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$landed" ] \
    || fail "the prescribed reset did not move a churn-only workspace onto the landing branch"
  assert_grep "folder_colors" "$log" \
    "the discarded hand-editable settings content was not captured before the reset"
  assert_grep "uid://rewritten" "$log" \
    "the discarded churn content was not captured before the reset"
  assert_grep "working: discarding Playbot churn before base reset:" "$status" \
    "no status line disclosed the discarded Playbot churn"
  assert_grep "prototype-game/project.godot" "$status" \
    "the status line does not name the discarded hand-editable settings file"
  assert_grep "prototype-game/addons/playbot/plugin.gd.uid" "$status" \
    "the status line does not name every discarded churn path"
  assert_no_grep "folder_colors" "$wt/prototype-game/project.godot" \
    "the reset left the churn in place, so the captured diff describes nothing"

  # Behind, with churn AND a real edit outside the eight paths: stop, report only
  # the offending path, reset nothing.
  wt="$TMP_ROOT/lane-churn-mixed-wt"
  git -C "$repo" worktree add -q -b task/lane-churn-mixed "$wt" "$stale"
  printf 'uid://rewritten\n' > "$wt/prototype-game/addons/playbot/plugin.gd.uid"
  printf 'real work\n' > "$wt/app.txt"
  outcome=$(lane_base_outcome "$wt" "$lane_ref" "$churn" "$log" "$status")
  [ "$outcome" = dirty ] \
    || fail "the prescribed base check reported '$outcome' for churn plus a real edit, not a stop"
  dirty=$(lane_base_dirty_paths "$wt" "$churn")
  assert_contains "$dirty" "app.txt" "the report does not name the offending path outside the allowlist"
  assert_not_contains "$dirty" "plugin.gd.uid" "the report blames Playbot churn for the block"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$stale" ] \
    || fail "the prescribed base check reset a workspace carrying work outside the allowlist"
  assert_grep "real work" "$wt/app.txt" "the prescribed base check discarded work outside the allowlist"

  # A modification elsewhere under the addons directory is not churn: the list is
  # eight literal paths, not a directory prefix.
  wt="$TMP_ROOT/lane-churn-neighbour-wt"
  git -C "$repo" worktree add -q -b task/lane-churn-neighbour "$wt" "$stale"
  printf 'uid://neighbour\n' > "$wt/prototype-game/addons/playbot/plugin.gd"
  git -C "$wt" add prototype-game/addons/playbot/plugin.gd
  outcome=$(lane_base_outcome "$wt" "$lane_ref" "$churn" "$log" "$status")
  [ "$outcome" = dirty ] \
    || fail "the prescribed base check treated a neighbouring addons path as churn (got '$outcome')"
  pass "fm-brief.sh: the lane base check discloses Playbot churn before resetting and still stops on real work"
}

# Firstmate began restating the delivery mode in every lane dispatch after lanes ran
# the no-mistakes pipeline on a local-only project. The brief must declare the mode
# prominently enough that no dispatch-time restatement is needed, while keeping the
# Definition of done the single authority, and bin/fm-spawn.sh's first-match read of
# the contract line must still see this task's mode.
test_lane_brief_declares_its_delivery_contract_prominently() {
  local home id mode brief first
  home="$TMP_ROOT/lane-contract-home"
  mkdir -p "$home/data"
  for mode in no-mistakes direct-PR local-only; do
    id="lane-contract-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" --lane --landing-branch proto/godot/frog-pile >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_grep "# Delivery contract - READ THIS BEFORE YOU SHIP ANYTHING" "$brief" \
      "$mode lane brief does not declare its delivery contract prominently"
    assert_grep "the full contract and the only delivery authority" "$brief" \
      "$mode lane brief does not keep the Definition of done as the single authority"
    assert_grep "this brief is complete and needs no dispatch-time override" "$brief" \
      "$mode lane brief does not tell the worker it needs no dispatch-time override"
    # The prominent block must sit above the setup and rules, not after them.
    [ "$(grep -n -F -m1 '# Delivery contract - READ THIS BEFORE YOU SHIP ANYTHING' "$brief" | cut -d: -f1)" \
      -lt "$(grep -n -F -m1 '# Setup' "$brief" | cut -d: -f1)" ] \
      || fail "$mode lane brief buries its delivery contract below the setup section"
    # fm-spawn.sh reads the FIRST contract line; it must be this task's mode.
    first=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$brief" | head -n 1)
    [ "$first" = "$mode" ] \
      || fail "$mode lane brief's first delivery contract line reads '$first', which fm-spawn.sh would refuse"
  done
  assert_grep "never run /no-mistakes. Firstmate lands your branch." \
    "$home/data/lane-contract-local-only/brief.md" \
    "local-only lane brief does not forbid the pipeline where it is most often run by mistake"
  assert_grep "Never run /no-mistakes on this task." \
    "$home/data/lane-contract-direct-PR/brief.md" \
    "direct-PR lane brief does not forbid the pipeline prominently"
  assert_grep "firstmate tells you when to run /no-mistakes" \
    "$home/data/lane-contract-no-mistakes/brief.md" \
    "no-mistakes lane brief does not say who starts the pipeline"
  pass "fm-brief.sh: a lane brief declares its delivery contract prominently and keeps one authority"
}

# An explicit workspace branch must be stated in all four places that used to name
# fm/<task-id>: the setup step, rule 1, the definition of done, and the ready line.
test_lane_branch_name_is_stated_in_every_branch_instruction() {
  local home brief
  home="$TMP_ROOT/lane-named-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" lane-named some-proj --mode local-only --lane \
    --lane-branch task/lane-named-2026-09-04 --landing-branch proto/godot/frog-pile >/dev/null 2>&1 \
    || fail "lane brief with an explicit branch should scaffold"
  brief="$home/data/lane-named/brief.md"
  assert_grep "verify it is your workspace branch \`task/lane-named-2026-09-04\`" "$brief" \
    "named lane brief does not state the branch in its setup step"
  assert_grep "Work only on your workspace branch \`task/lane-named-2026-09-04\`; never create or switch branches." "$brief" \
    "named lane brief does not state the branch in rule 1"
  assert_grep "complete only when committed on your workspace branch \`task/lane-named-2026-09-04\`" "$brief" \
    "named lane brief does not state the branch in its definition of done"
  assert_grep "append \`done: ready in branch task/lane-named-2026-09-04\` to the status file" "$brief" \
    "named lane brief does not report readiness on its workspace branch"
  assert_no_grep "ready in branch fm/" "$brief" \
    "named lane brief still reports readiness on an fm/ branch"

  # direct-PR pushes the workspace branch, and no-mistakes works on it.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" lane-named-pr some-proj --mode direct-PR --lane \
    --lane-branch task/lane-named-pr-2026-09-04 --landing-branch proto/godot/frog-pile >/dev/null 2>&1
  assert_grep "push only your workspace branch \`task/lane-named-pr-2026-09-04\`; never create or switch branches" \
    "$home/data/lane-named-pr/brief.md" \
    "named direct-PR lane brief does not push the workspace branch"
  # A lane's PR must target its landing branch: gh pr create with no --base opens
  # against the repository default, which is not where a lane lands.
  assert_grep "passing \`--base proto/godot/frog-pile\` explicitly so the PR targets your landing branch" \
    "$home/data/lane-named-pr/brief.md" \
    "direct-PR lane brief does not name the landing branch as the PR base"
  pass "fm-brief.sh: an explicit lane branch is stated in every branch instruction"
}

# A lane brief must stay coherent with no branch name available: it refers to the
# branch the workspace was created on rather than inventing one, and the readiness
# line tells the worker to name its own branch.
test_lane_without_a_branch_name_stays_coherent() {
  local home brief
  home="$TMP_ROOT/lane-unnamed-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" lane-unnamed some-proj --mode local-only --lane \
    --landing-branch proto/godot/frog-pile >/dev/null 2>&1 \
    || fail "lane brief without a branch name should scaffold"
  brief="$home/data/lane-unnamed/brief.md"
  assert_grep "verify it is the branch your workspace was created on" "$brief" \
    "unnamed lane brief does not refer to the branch the workspace was created on"
  assert_grep "Work only on the branch your workspace was created on; never create or switch branches." "$brief" \
    "unnamed lane brief lost branch ownership in rule 1"
  assert_grep "complete only when committed on the branch your workspace was created on" "$brief" \
    "unnamed lane brief lost branch ownership in its definition of done"
  assert_grep "append \`done: ready in branch {your workspace branch}\` to the status file" "$brief" \
    "unnamed lane brief does not have the worker name its own branch when reporting ready"
  assert_no_grep "fm/lane-unnamed" "$brief" \
    "unnamed lane brief fell back to the crewmate branch convention"
  pass "fm-brief.sh: a lane brief without a branch name stays coherent"
}

# Every lane flag combination that cannot mean anything must fail with a clear
# message and write nothing, rather than emitting a brief whose lane wording
# contradicts its own kind.
test_lane_flag_combinations_are_refused() {
  local home out status label args expect
  home="$TMP_ROOT/lane-refused-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
    assert_absent "$home/data/${args%% *}/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
lane on a scout brief|lane-refused-c1 some-proj --scout --lane|--lane applies only to ship briefs
lane on a secondmate charter|lane-refused-c2 --secondmate --no-projects --lane|--lane applies only to ship briefs
lane branch without lane|lane-refused-c3 some-proj --mode no-mistakes --lane-branch task/x|--lane-branch requires --lane
lane branch with no value|lane-refused-c4 some-proj --mode no-mistakes --lane --lane-branch|--lane-branch requires a value
empty lane branch|lane-refused-c5 some-proj --mode no-mistakes --lane --lane-branch=|--lane-branch requires a value
landing branch without lane|lane-refused-c6 some-proj --mode no-mistakes --landing-branch main|--landing-branch requires --lane
landing branch with no value|lane-refused-c7 some-proj --mode no-mistakes --lane --landing-branch|--landing-branch requires a value
empty landing branch|lane-refused-c8 some-proj --mode no-mistakes --lane --landing-branch=|--landing-branch requires a value
landing branch as a remote ref path|lane-refused-c10 some-proj --mode no-mistakes --lane --landing-branch refs/remotes/origin/main|--landing-branch names a branch, not a ref path
landing branch as a qualified branch ref|lane-refused-c11 some-proj --mode no-mistakes --lane --landing-branch refs/heads/main|--landing-branch names a branch, not a ref path
lane still needs a mode|lane-refused-c9 some-proj --lane|ship briefs require --mode
lane without a landing branch|lane-refused-c12 some-proj --mode no-mistakes --lane|--lane requires --landing-branch
ROWS
  pass "fm-brief.sh: nonsensical lane flag combinations are refused, never emitted as a confusing brief"
}

# Both lane branch flags are rendered into commands the brief tells the worker to
# run, so an unsafe, git-invalid or fully-qualified value must never reach a
# generated brief. These are string checks only: fm-brief.sh cannot know which
# clone a lane will use, so an existence judgement belongs to the brief's own step
# 1b, and a value like origin/main is accepted here on purpose.
test_lane_branch_values_must_be_safe_branch_names() {
  local home out status id value flag brief
  home="$TMP_ROOT/lane-branch-value-home"
  mkdir -p "$home/data"
  id=0
  for flag in --landing-branch --lane-branch; do
    # shellcheck disable=SC2016  # these are literal unsafe values under test; nothing may expand
    for value in '$(id)' 'a`id`b' 'main;rm' 'main|tee' 'main~1' 'main..x' '.hidden' 'HEAD' 'x.lock' 'refs/heads/foo' 'refs/remotes/origin/main'; do
      id=$((id + 1))
      out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "value-$id" some-proj --mode no-mistakes --lane \
        --landing-branch main "$flag" "$value" 2>&1)
      status=$?
      [ "$status" -ne 0 ] \
        || fail "$flag '$value' scaffolded instead of being refused"
      assert_contains "$out" "$flag" "$flag '$value': refusal does not name the flag"
      assert_absent "$home/data/value-$id/brief.md" \
        "$flag '$value': a refused value still wrote a brief"
    done
  done
  # The safe forms the refusals must not catch. proto/godot/frog-pile is this
  # system's canonical landing-branch spelling, so it must scaffold and must be
  # what the generated base check resolves.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" value-ok some-proj --mode no-mistakes --lane \
    --landing-branch proto/godot/frog-pile --lane-branch task/value-ok-2026-09-04 >/dev/null 2>&1 \
    || fail "the canonical multi-segment landing branch should scaffold"
  brief="$home/data/value-ok/brief.md"
  assert_present "$brief" "the canonical multi-segment landing branch wrote no brief"
  assert_grep "git rev-list --left-right --count refs/heads/proto/godot/frog-pile...HEAD" "$brief" \
    "the canonical landing branch is not what the base check resolves"
  assert_grep "run \`git reset --hard refs/heads/proto/godot/frog-pile\`" "$brief" \
    "the canonical landing branch is not what a behind workspace resets onto"

  # A remote-tracking spelling is accepted at scaffold time on purpose: only the
  # lane worktree can say whether refs/heads/origin/main exists, and the generated
  # step 1b stops when it does not.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" value-remote some-proj --mode no-mistakes --lane \
    --landing-branch origin/main >/dev/null 2>&1 \
    || fail "a ref-safe remote-tracking spelling should scaffold and be settled at step 1b"
  assert_grep "git rev-parse --verify --quiet refs/heads/origin/main" \
    "$home/data/value-remote/brief.md" \
    "the accepted value is not handed to the brief's fail-closed existence guard"
  pass "fm-brief.sh: --landing-branch and --lane-branch refuse values that are not plain branch names"
}

# Lane mode must not change a non-lane brief at all. Comparing each mode's whole
# generated brief against a committed fixture catches any drift, including drift a
# targeted assertion would not think to look for. Regenerate deliberately with
# FM_BRIEF_FIXTURE_UPDATE=1 and review the diff; never regenerate to silence a
# failure you did not intend.
test_non_lane_ship_briefs_match_their_fixture() {
  local home mode brief fixture normalized
  home="$TMP_ROOT/fixture-home"
  mkdir -p "$home/data"
  for mode in no-mistakes direct-PR local-only; do
    FM_HOME="$home" FM_ROOT_OVERRIDE=/FM_ROOT FM_CLASSIFY_PAUSED_VERB=paused \
      "$ROOT/bin/fm-brief.sh" "fixture-$mode" fixture-project --mode "$mode" >/dev/null 2>&1 \
      || fail "$mode: fixture brief should scaffold"
    brief="$home/data/fixture-$mode/brief.md"
    fixture="$ROOT/tests/fixtures/fm-brief/ship-$mode.md"
    normalized="$home/normalized-$mode.md"
    sed -e "s|$home|/FM_HOME|g" -e "s|$ROOT|/FM_ROOT|g" "$brief" > "$normalized"
    if [ -n "${FM_BRIEF_FIXTURE_UPDATE:-}" ]; then
      cp "$normalized" "$fixture"
      continue
    fi
    assert_present "$fixture" "$mode: missing committed brief fixture"
    cmp -s "$fixture" "$normalized" \
      || fail "$mode: non-lane brief drifted from tests/fixtures/fm-brief/ship-$mode.md - $(diff -u "$fixture" "$normalized" | head -n 20)"
  done
  if [ -n "${FM_BRIEF_FIXTURE_UPDATE:-}" ]; then
    pass "fm-brief.sh: non-lane ship brief fixtures regenerated (FM_BRIEF_FIXTURE_UPDATE)"
    return 0
  fi
  pass "fm-brief.sh: non-lane ship briefs are byte-identical to their committed fixtures"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_learning_capture_command_binds_origin_home
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
test_lane_mode_drops_the_crewmate_branch_convention
test_lane_brief_verifies_its_base_before_working
test_lane_base_check_detects_an_unpushed_landing
test_lane_base_check_never_resolves_a_remote_or_tag_ref
test_lane_base_check_discloses_before_resetting_playbot_churn
test_lane_brief_declares_its_delivery_contract_prominently
test_lane_branch_name_is_stated_in_every_branch_instruction
test_lane_without_a_branch_name_stays_coherent
test_lane_flag_combinations_are_refused
test_lane_branch_values_must_be_safe_branch_names
test_non_lane_ship_briefs_match_their_fixture
