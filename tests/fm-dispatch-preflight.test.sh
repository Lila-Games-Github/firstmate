#!/usr/bin/env bash
# Regression tests for fm-spawn's dispatch preflight
# (bin/fm-dispatch-preflight-lib.sh owns the probes and the brief marker forms).
#
# Each case drives the real spawn path with a fake terminal against a project
# whose origin has advanced past the pooled worktree, so a refusal can be shown
# to happen after the base refresh and before any worker or task record exists.
# The cases replay the incidents the preflight exists for: a ship worktree with
# no Git commit identity, a brief naming a path or symbol absent from the
# recorded landing branch, and a required service the selected harness cannot
# call, with and without preserved raw inputs to bundle instead.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-dispatch-preflight-lib.sh
. "$ROOT/bin/fm-dispatch-preflight-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dispatch-preflight)
LANDING=proto/godot/frog-pile

commit_as_fixture() {  # <repo> <message>
  git -C "$1" add -A
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
}

# make_case <name> <id>: project + bare origin + detached pool at the initial
# commit; origin's default branch then advances, and a landing branch carries
# the FrogPile-style inputs the default branch lacks.
make_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  POOL_DIR="$CASE_DIR/pool"
  local origin="$CASE_DIR/origin.git" publisher="$CASE_DIR/publisher"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  touch "$HOME_DIR/state/.last-watcher-beat"

  git init --quiet -b main "$PROJECT_DIR"
  printf 'base\n' > "$PROJECT_DIR/README.md"
  printf 'func _draw_star_v2():\n\tpass\n' > "$PROJECT_DIR/effect.gd"
  commit_as_fixture "$PROJECT_DIR" initial
  git clone --quiet --bare "$PROJECT_DIR" "$origin"
  git -C "$PROJECT_DIR" remote add origin "file://$origin"
  INITIAL_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$INITIAL_SHA"

  git clone --quiet "file://$origin" "$publisher"
  printf 'advanced\n' > "$publisher/advanced-main.txt"
  commit_as_fixture "$publisher" advance-main
  git -C "$publisher" push --quiet origin main
  git -C "$publisher" checkout --quiet -b "$LANDING" "$INITIAL_SHA"
  mkdir -p "$publisher/prototype-game/docs/wiki"
  printf 'schema\n' > "$publisher/prototype-game/docs/wiki/documentation-schema.md"
  printf 'func _draw_star():\n\tpass\n' > "$publisher/prototype-game/level_up_effect.gd"
  commit_as_fixture "$publisher" landing-tip
  git -C "$publisher" push --quiet origin "$LANDING"
  git -C "$PROJECT_DIR" fetch --quiet origin
  write_brief "$id" ''
}

write_brief() {  # <id> <marker lines>
  mkdir -p "$HOME_DIR/data/$1"
  cat > "$HOME_DIR/data/$1/brief.md" <<EOF
# Task
## Captain's intent
Exercise the dispatch preflight for $1.

## Firstmate spec
Launch only when the preflight passes.
$2
EOF
}

run_spawn() {  # <id> [spawn args...]
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

assert_refused_before_worker() {  # <id> <status> <label>
  [ "$2" -ne 0 ] || fail "$3: spawn succeeded"
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "$3: a refused spawn published a task record"
}

test_ship_without_git_identity_refuses_and_clone_identity_fixes_it() {
  local out status
  make_case identity id-ship-r1
  # Disable host auto-detection so the verdict never depends on the hostname.
  git -C "$PROJECT_DIR" config user.useConfigOnly true

  out=$(FM_TEST_SPAWN_GIT_IDENTITY=0 run_spawn id-ship-r1 --mode direct-PR --yolo off)
  status=$?
  assert_refused_before_worker id-ship-r1 "$status" "a ship worktree with no commit identity"
  assert_contains "$out" "no resolvable Git author/committer identity" \
    "the refusal did not name the missing identity"$'\n'"$out"
  assert_contains "$out" "registration" "the refusal did not name the clone-registration remedy"
  assert_contains "$out" "git -C $PROJECT_DIR config user.email" \
    "the refusal did not show the clone identity command"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$PROJECT_DIR" rev-parse origin/main)" ] \
    || fail "the identity refusal ran before the base refresh"

  write_brief id-scout-r1 ''
  out=$(FM_TEST_SPAWN_GIT_IDENTITY=0 run_spawn id-scout-r1 --scout)
  expect_code 0 $? "a scout needs no commit identity and should launch"$'\n'"$out"

  git -C "$PROJECT_DIR" config user.name 'Registered Clone'
  git -C "$PROJECT_DIR" config user.email clone@example.invalid
  write_brief id-ship-r1b ''
  out=$(FM_TEST_SPAWN_GIT_IDENTITY=0 run_spawn id-ship-r1b --mode direct-PR --yolo off)
  expect_code 0 $? "a clone identity configured at registration should satisfy the preflight"$'\n'"$out"
  pass "a ship spawn refuses a worktree with no commit identity, and the clone-registration remedy clears it"
}

test_identity_probe_honors_the_launch_env_allowlist() {
  local out status
  make_case identity-env id-env-r2
  git -C "$PROJECT_DIR" config user.useConfigOnly true
  export GIT_AUTHOR_NAME='Env Only' GIT_AUTHOR_EMAIL=env@example.invalid
  export GIT_COMMITTER_NAME='Env Only' GIT_COMMITTER_EMAIL=env@example.invalid

  out=$(FM_TEST_SPAWN_GIT_IDENTITY=0 run_spawn id-env-r2 --mode direct-PR --yolo off)
  expect_code 0 $? "an ambient identity reaches an unfiltered launch"$'\n'"$out"

  printf '# nothing beyond the floor\n' > "$HOME_DIR/config/launch-env-allowlist"
  write_brief id-env-r2b ''
  out=$(FM_TEST_SPAWN_GIT_IDENTITY=0 run_spawn id-env-r2b --mode direct-PR --yolo off)
  status=$?
  assert_refused_before_worker id-env-r2b "$status" "an identity the allowlist filters out"
  assert_contains "$out" "GIT_AUTHOR_IDENT does not resolve" "the filtered refusal did not name the probe"

  printf 'GIT_AUTHOR_NAME\nGIT_AUTHOR_EMAIL\nGIT_COMMITTER_NAME\nGIT_COMMITTER_EMAIL\n' \
    > "$HOME_DIR/config/launch-env-allowlist"
  write_brief id-env-r2c ''
  out=$(FM_TEST_SPAWN_GIT_IDENTITY=0 run_spawn id-env-r2c --mode direct-PR --yolo off)
  expect_code 0 $? "an allowlisted identity reaches the filtered launch"$'\n'"$out"
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  pass "the identity probe sees only what the launch environment passes through"
}

test_existing_inputs_resolve_against_the_landing_branch() {
  local out status markers
  markers='Existing input: path prototype-game/docs/wiki/documentation-schema.md
Existing input: symbol _draw_star'
  make_case inputs in-default-r3
  write_brief in-default-r3 "$markers"

  # The frogpile-merge-v2-wiki incident: cut from main, where the inputs are absent.
  out=$(run_spawn in-default-r3 --mode no-mistakes --yolo off)
  status=$?
  assert_refused_before_worker in-default-r3 "$status" "a brief whose inputs are absent from its base"
  assert_contains "$out" "re-triage" "the refusal did not route the brief back for re-triage"$'\n'"$out"
  assert_contains "$out" "path prototype-game/docs/wiki/documentation-schema.md" \
    "the refusal did not name the absent path"
  # The default branch holds only _draw_star_v2: a substring must not count.
  assert_contains "$out" "symbol _draw_star" "the refusal did not name the absent symbol"

  write_brief in-landing-r3 "$markers"
  out=$(run_spawn in-landing-r3 --mode no-mistakes --yolo off --landing-branch "$LANDING")
  expect_code 0 $? "inputs present on the recorded landing branch should launch"$'\n'"$out"

  # The draw-star incident: the symbol was deleted on the landing branch.
  write_brief in-symbol-r3 'Existing input: symbol LevelUpEffect_removed_draw_path'
  out=$(run_spawn in-symbol-r3 --scout)
  status=$?
  assert_refused_before_worker in-symbol-r3 "$status" "a scout brief naming a deleted symbol"
  assert_contains "$out" "symbol LevelUpEffect_removed_draw_path" "the scout refusal did not name the symbol"

  write_brief in-word-r3 'Existing input: symbol _draw_star_v2'
  out=$(run_spawn in-word-r3 --scout)
  expect_code 0 $? "a whole-word symbol on the default branch should launch"$'\n'"$out"
  pass "existing inputs resolve against the recorded landing branch and a stale brief goes back for re-triage"
}

test_malformed_markers_refuse_before_any_endpoint() {
  local out status marker
  for marker in 'Existing input: path ../outside.md' 'Existing input: file README.md' \
    'Required tool: browser chrome' 'Preserved input: relative/archive.zip'; do
    make_case "malformed-$RANDOM" bad-marker-r4
    write_brief bad-marker-r4 "$marker"
    out=$(run_spawn bad-marker-r4 --scout)
    status=$?
    assert_refused_before_worker bad-marker-r4 "$status" "malformed marker '$marker'"
    assert_contains "$out" "malformed dispatch preflight marker" "no malformed-marker refusal for '$marker'"$'\n'"$out"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$INITIAL_SHA" ] \
      || fail "malformed marker '$marker' was only refused after the worktree was refreshed"
  done
  pass "malformed preflight markers refuse before any endpoint or worktree change"
}

write_fake_codex() {  # <auth_status for figma>
  cat > "$FAKEBIN_DIR/codex" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2 \$3" = 'mcp list --json' ]; then
  printf '[{"name":"figma","enabled":true,"auth_status":"%s"},{"name":"off","enabled":false,"auth_status":"o_auth"}]\n' '$1'
  exit 0
fi
exit 0
SH
  chmod +x "$FAKEBIN_DIR/codex"
}

test_required_tools_are_probed_or_preserved_inputs_bundled() {
  local out status record bundle
  make_case tools tool-ok-r5
  fm_fake_exit0 "$FAKEBIN_DIR" fm-fake-viewer
  write_fake_codex o_auth
  write_brief tool-ok-r5 'Required tool: command fm-fake-viewer
Required tool: mcp figma'
  out=$(run_spawn tool-ok-r5 --scout)
  expect_code 0 $? "callable tools should launch"$'\n'"$out"
  record="$HOME_DIR/data/tool-ok-r5/dispatch-preflight.md"
  # shellcheck disable=SC2016 # the record quotes markers in Markdown backticks
  assert_grep 'Required tool `command fm-fake-viewer`: callable' "$record" "the command tool was not recorded callable"
  # shellcheck disable=SC2016 # the record quotes markers in Markdown backticks
  assert_grep 'Required tool `mcp figma`: callable' "$record" "the codex mcp tool was not recorded callable"
  assert_grep '# Dispatch preflight' "$HOME_DIR/data/tool-ok-r5/launch-brief.md" \
    "the worker's launch brief does not carry the preflight record"
  [ ! -e "$HOME_DIR/data/tool-ok-r5/inputs" ] || fail "callable tools still bundled inputs"

  # The creature-review incident: the harness cannot reach Figma and the brief
  # preserved nothing to fall back on.
  write_fake_codex not_logged_in
  write_brief tool-none-r5 'Required tool: mcp figma'
  out=$(run_spawn tool-none-r5 --scout)
  status=$?
  assert_refused_before_worker tool-none-r5 "$status" "an uncallable tool with no preserved inputs"
  assert_contains "$out" "not callable for tool-none-r5 in harness codex" "the refusal did not name the harness"$'\n'"$out"
  assert_contains "$out" "Preserved input" "the refusal did not name the bundling remedy"

  mkdir -p "$CASE_DIR/board-archive"
  printf 'original art bytes\n' > "$CASE_DIR/board-archive/creature.png"
  write_brief tool-bundle-r5 "Required tool: mcp figma
Preserved input: $CASE_DIR/board-archive"
  out=$(run_spawn tool-bundle-r5 --scout)
  expect_code 0 $? "an uncallable tool with preserved inputs should bundle and launch"$'\n'"$out"
  bundle="$HOME_DIR/data/tool-bundle-r5/inputs"
  cmp -s "$CASE_DIR/board-archive/creature.png" "$bundle/board-archive/creature.png" \
    || fail "the preserved input was not copied byte-identical into the task bundle"
  record="$HOME_DIR/data/tool-bundle-r5/dispatch-preflight.md"
  assert_grep 'NOT callable in this worker (codex lists no enabled, authenticated server named figma)' "$record" \
    "the record did not say the tool was not callable and why"
  assert_grep '- Bundled instead:' "$record" "the record did not say the inputs were bundled"
  assert_grep '- Bundled instead:' "$HOME_DIR/data/tool-bundle-r5/launch-brief.md" \
    "the worker's launch brief does not say the inputs were bundled"
  assert_contains "$out" "bundled the preserved inputs" "the spawn did not report which outcome happened"

  write_brief tool-missing-r5 "Required tool: mcp figma
Preserved input: $CASE_DIR/no-such-archive"
  out=$(run_spawn tool-missing-r5 --scout)
  status=$?
  assert_refused_before_worker tool-missing-r5 "$status" "a preserved input that does not exist"
  assert_contains "$out" "$CASE_DIR/no-such-archive does not exist" "the refusal did not name the missing preserved input"
  pass "required tools are probed in the selected harness, else preserved inputs are bundled and the outcome recorded"
}

test_claude_mcp_probe_reads_the_status_line() {
  local out record
  make_case claude-mcp claude-mcp-r6
  cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = 'mcp get' ]; then
  case "$3" in figma|slack) printf '%s:\n  Scope: claude.ai config\n' "$3" ;; esac
  case "$3" in
    figma) printf '  Status: \xe2\x9c\x94 Connected\n' ;;
    slack) printf '  Status: ! Needs authentication\n' ;;
    *) printf 'No MCP server named "%s".\n' "$3"; exit 1 ;;
  esac
  exit 0
fi
exit 0
SH
  chmod +x "$FAKEBIN_DIR/claude"
  mkdir -p "$CASE_DIR/export"
  printf 'thread\n' > "$CASE_DIR/export/thread.txt"
  write_brief claude-mcp-r6 "Required tool: mcp figma
Required tool: mcp slack
Preserved input: $CASE_DIR/export"
  out=$(run_spawn claude-mcp-r6 --scout --harness claude)
  expect_code 0 $? "a claude spawn with one uncallable tool and preserved inputs should launch"$'\n'"$out"
  record="$HOME_DIR/data/claude-mcp-r6/dispatch-preflight.md"
  # shellcheck disable=SC2016 # the record quotes markers in Markdown backticks
  assert_grep 'Required tool `mcp figma`: callable' "$record" "a connected claude server was not callable"
  # shellcheck disable=SC2016 # the record quotes markers in Markdown backticks
  assert_grep 'Required tool `mcp slack`: NOT callable in this worker (claude reports Status: ! Needs authentication)' "$record" \
    "an unauthenticated claude server was not reported with its status"
  [ -f "$HOME_DIR/data/claude-mcp-r6/inputs/export/thread.txt" ] || fail "the claude case did not bundle its preserved input"

  # The CLI exits 1 naming no such server for an unknown name.
  PATH="$FAKEBIN_DIR:$PATH" fm_preflight_mcp_callable "$CASE_DIR" claude 0 nosuch && fail "an unknown claude server counted as callable"
  assert_contains "$FM_PREFLIGHT_REASON" "no server named nosuch" "the unknown-server reason was not explained"
  fm_preflight_mcp_callable "$CASE_DIR" grok 0 figma && fail "a harness with no verified probe counted as callable"
  assert_contains "$FM_PREFLIGHT_REASON" "grok has no verified MCP probe" "the unverified-harness reason was not explained"
  fm_preflight_mcp_callable "$CASE_DIR" codex 1 figma && fail "a raw launch command counted as callable"
  pass "the claude probe reads the Status line and unverified harnesses never count as callable"
}

test_ship_without_git_identity_refuses_and_clone_identity_fixes_it
test_identity_probe_honors_the_launch_env_allowlist
test_existing_inputs_resolve_against_the_landing_branch
test_malformed_markers_refuse_before_any_endpoint
test_required_tools_are_probed_or_preserved_inputs_bundled
test_claude_mcp_probe_reads_the_status_line

echo "# all fm-dispatch-preflight tests passed"
