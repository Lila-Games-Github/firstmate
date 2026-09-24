#!/usr/bin/env bash
# tests/fm-codex-catalog-lib.test.sh - unit tests for the Codex model-catalog
# library (bin/fm-codex-catalog-lib.sh), the single owner of deciding which
# reasoning levels an installed Codex model supports. Pure functions against
# fixture catalog files; no backend and no live spawn required. Behavioral
# coverage of the spawn-time refuse-vs-emit contract this library backs lives
# in tests/fm-spawn-dispatch-profile.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-codex-catalog-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-catalog-lib)

write_catalog() {
  local dir=$1 body=$2
  mkdir -p "$dir"
  printf '%s' "$body" > "$dir/models_cache.json"
}

# assert_supports_level_rc <expected-rc> <codex-home> <model> <level> <message>
assert_supports_level_rc() {
  local expected=$1 codex_home=$2 model=$3 level=$4 message=$5 rc=0
  CODEX_HOME="$codex_home" fm_codex_model_supports_level "$model" "$level" || rc=$?
  [ "$rc" -eq "$expected" ] || fail "$message (expected $expected, got $rc)"
}

# --- fm_codex_catalog_path ----------------------------------------------------

( unset CODEX_HOME; HOME=/home/nobody fm_codex_catalog_path ) | grep -qx '/home/nobody/.codex/models_cache.json' \
  || fail "fm_codex_catalog_path must default to \$HOME/.codex/models_cache.json when CODEX_HOME is unset"
CODEX_HOME=/custom/codex fm_codex_catalog_path | grep -qx '/custom/codex/models_cache.json' \
  || fail "fm_codex_catalog_path must honor CODEX_HOME when set"
pass "fm_codex_catalog_path resolves CODEX_HOME, falling back to \$HOME/.codex"

# --- fm_codex_model_supports_level: readable catalog --------------------------

CATALOG_DIR="$TMP_ROOT/readable"
write_catalog "$CATALOG_DIR" '{"models":[
  {"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}]},
  {"slug":"gpt-5","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]}
]}'

assert_supports_level_rc 0 "$CATALOG_DIR" gpt-6-luna max \
  "a model whose catalog entry lists max must report supported (0)"
assert_supports_level_rc 2 "$CATALOG_DIR" gpt-5 max \
  "a model whose catalog entry omits max must report unsupported (2), not unverifiable (1)"
assert_supports_level_rc 2 "$CATALOG_DIR" gpt-9-nonexistent max \
  "a model absent from the catalog must report unsupported (2)"
assert_supports_level_rc 0 "$CATALOG_DIR" gpt-5 high \
  "a listed non-max level must still report supported (0)"
pass "fm_codex_model_supports_level reads a live catalog entry per model and level"

# --- fm_codex_model_supports_level: unreadable/missing/malformed catalog ------

assert_supports_level_rc 1 "$TMP_ROOT/missing" gpt-6-luna max \
  "a missing catalog file must report unverifiable (1), never supported"

MALFORMED_DIR="$TMP_ROOT/malformed"
write_catalog "$MALFORMED_DIR" 'not json'
assert_supports_level_rc 1 "$MALFORMED_DIR" gpt-6-luna max \
  "invalid JSON must report unverifiable (1), never supported"

UNREADABLE_DIR="$TMP_ROOT/unreadable"
write_catalog "$UNREADABLE_DIR" '{"models":[]}'
chmod 000 "$UNREADABLE_DIR/models_cache.json"
if [ "$(id -u)" -ne 0 ]; then
  assert_supports_level_rc 1 "$UNREADABLE_DIR" gpt-6-luna max \
    "a permission-denied catalog file must report unverifiable (1), never supported"
fi
chmod 600 "$UNREADABLE_DIR/models_cache.json"
pass "fm_codex_model_supports_level treats a missing, malformed, or unreadable catalog as unverifiable, never as support"

echo "# all fm-codex-catalog-lib tests passed"
