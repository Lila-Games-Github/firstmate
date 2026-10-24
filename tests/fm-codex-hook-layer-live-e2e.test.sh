#!/usr/bin/env bash
# Live guard for the codex crewmate launch flags.
#
# The verdicts here come from the installed codex, not from a stub: a stub can
# only confirm the assumption already written into it, and what this guard
# protects is exactly a vendor-owned surface.
#
# Codex blocks a fresh crewmate launch on an unanswerable "Hooks need review"
# modal whenever the machine's ~/.codex/hooks.json or a project's
# .codex/hooks.json carries a hook it has no persisted trust for, so the
# crewmate launch disables codex's hook layer outright (bin/fm-spawn.sh's launch
# template owns the flag).
# Codex likewise draws an interactive "Update available! ... Press enter to
# continue" prompt at its startup when a newer release exists on the machine,
# which parks a resumed worker no human is there to answer, so the launch turns
# the startup update check off the same way.
#
# The guard replays the REAL launch flags fm-spawn builds - captured from a
# spawn driven through a fake pane - against the installed codex and asks codex
# itself for the effective state those flags resolve to. If a codex release
# renames or drops what they configure, this guard fails naming the harness and
# version instead of letting the modal come back.
#
# It spends no model tokens (`codex features list` and `codex doctor --json`
# resolve configuration only), so it runs by default wherever codex is
# installed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CODEX_HOOK_LAYER_LIVE codex

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-layer-live)

# capture_codex_launch <name> <extra fm-spawn args...>: spawns a codex crewmate
# against a fake pane and echoes the literal launch command firstmate sent.
capture_codex_launch() {
  local name=$1
  shift
  local case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id="codex-hook-layer-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" >/dev/null 2>&1 ||
    fail "codex $CODEX_VERSION: fm-spawn could not build a crewmate launch"
  cat "$launchlog"
}

# codex_global_flags <launch command>: the flags between the codex executable
# and the positional brief, which is everything codex itself is configured by.
codex_global_flags() {
  local launch=$1 flags
  flags=${launch#*codex }
  flags=${flags%%\"\$(*}
  printf '%s' "$flags"
}

# codex_update_check_state <flags>: the value codex itself reports for its
# startup update check once <flags> are applied, read from the effective
# configuration `codex doctor --json` describes. Prints nothing when the
# installed codex does not report that field at all.
codex_update_check_state() {
  local flags=$1 report
  report=$(eval "codex $flags doctor --json" 2>/dev/null) || true
  printf '%s' "$report" \
    | jq -r '.checks."updates.status".details."check for update on startup" // empty' 2>/dev/null
}

test_installed_codex_suppresses_the_update_prompt_for_the_captured_crewmate_launch() {
  local launch flags armed off
  launch=$(capture_codex_launch update-prompt --mode no-mistakes --yolo off)
  flags=$(codex_global_flags "$launch")

  # Disconfirming control first: the same key set the other way must read true,
  # so a codex that stopped reporting the effective value - or reported a
  # constant - cannot pass this guard by printing the answer it wants.
  armed=$(codex_update_check_state "-c check_for_update_on_startup=true")
  [ "$armed" = true ] \
    || fail "codex $CODEX_VERSION did not report check_for_update_on_startup=true for an explicit override (got '$armed'), so the startup update check this launch disables can no longer be read and the interactive update prompt may have come back unguarded"

  off=$(codex_update_check_state "$flags")
  [ "$off" = false ] \
    || fail "codex $CODEX_VERSION left the startup update check on for firstmate's crewmate launch flags (got '$off'), so a host restart can park a resumed worker on the interactive update prompt"

  printf 'ok - codex %s runs a firstmate crewmate launch with the startup update prompt suppressed\n' "$CODEX_VERSION"
}

test_installed_codex_disables_hooks_for_the_captured_crewmate_launch() {
  local launch flags state
  launch=$(capture_codex_launch ship --mode no-mistakes --yolo off)
  flags=$(codex_global_flags "$launch")

  # The whole point: every flag firstmate will launch with, handed to the real
  # codex, must leave the hook layer off. `features list` reports the effective
  # state after those flags are applied and contacts no model.
  state=$(eval "codex $flags features list" 2>&1) ||
    fail "codex $CODEX_VERSION rejected firstmate's crewmate launch flags: $state"
  case "$state" in
    *"Unknown feature flag"*)
      fail "codex $CODEX_VERSION no longer knows the hook feature firstmate disables: $state"
      ;;
  esac
  printf '%s\n' "$state" | awk '$1 == "hooks" { print $NF }' | grep -qx false ||
    fail "codex $CODEX_VERSION left hooks enabled for firstmate's crewmate launch flags, so a fresh launch can park on the hook-trust modal"

  printf 'ok - codex %s runs a firstmate crewmate launch with its hook layer disabled\n' "$CODEX_VERSION"
}

test_installed_codex_still_reports_the_hook_feature() {
  local listing
  listing=$(codex features list 2>&1) ||
    fail "codex $CODEX_VERSION could not list its feature flags: $listing"
  printf '%s\n' "$listing" | awk '{ print $1 }' | grep -qx hooks ||
    fail "codex $CODEX_VERSION no longer publishes a hook feature flag; firstmate's crewmate launch needs a new control"

  printf 'ok - codex %s still publishes the hook feature flag firstmate disables\n' "$CODEX_VERSION"
}

test_installed_codex_still_reports_the_hook_feature
test_installed_codex_disables_hooks_for_the_captured_crewmate_launch
test_installed_codex_suppresses_the_update_prompt_for_the_captured_crewmate_launch

echo "# all fm-codex-hook-layer-live-e2e tests passed"
