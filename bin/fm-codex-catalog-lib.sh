# shellcheck shell=bash
# fm-codex-catalog-lib.sh - the ONE owner of reading the installed Codex CLI's
# model catalog to decide which reasoning levels a model supports.
#
# Codex CLI writes its fetched catalog to
# ${CODEX_HOME:-~/.codex}/models_cache.json as {"models":[{"slug":<id>,
# "supported_reasoning_levels":[{"effort":<level>,...}, ...]}, ...]}
# (verified codex-cli 0.155.1). This is the live source of which models
# advertise which reasoning levels, including max, replacing an earlier
# hard-coded "max is valid only for gpt-5.6-luna" rule that went stale the
# moment the catalog started advertising max for other models too
# (gpt-6-luna, gpt-6-sol, gpt-6-astra, gpt-5.6-sol, gpt-5.6-terra as of
# 2026-09-24) while a spawn using one of them silently ran without the flag
# instead of at the requested effort. Nothing here may hard-code a model
# name.
#
# Usage: . bin/fm-codex-catalog-lib.sh
#
# fm_codex_catalog_path
#   Echoes the resolved catalog path.
#
# fm_codex_model_supports_level <model> <level>
#   0  the catalog is readable, valid JSON, and the named model's
#      supported_reasoning_levels lists <level>.
#   1  the catalog is missing, unreadable, or not valid JSON, or jq is not on
#      PATH; supportability could not be confirmed.
#   2  the catalog is readable and valid, but the named model is absent from
#      it or does not list <level>.
#
# config/crew-dispatch.json's static bootstrap and typed-dispatch validation
# (bin/fm-bootstrap.sh, bin/fm-dispatch-resolve.sh) keep their own separate,
# catalog-independent allow-list for codex max: they check a profile before
# any worker is provisioned, on hosts that may never have run codex CLI, and
# a config-linter that started rejecting or accepting profiles based on
# whether a catalog file happens to be present would be a materially
# different contract than the deterministic one their tests already pin.
# This library's job is the live spawn-time decision in bin/fm-spawn.sh only.

fm_codex_catalog_path() {
  printf '%s/models_cache.json\n' "${CODEX_HOME:-$HOME/.codex}"
}

fm_codex_model_supports_level() {  # <model> <level>
  local model=$1 level=$2 catalog result
  catalog=$(fm_codex_catalog_path)
  command -v jq >/dev/null 2>&1 || return 1
  [ -r "$catalog" ] || return 1
  result=$(jq -r --arg m "$model" --arg l "$level" '
    (.models // []) | map(select(.slug == $m)) | first as $entry
    | if $entry == null then "absent"
      elif (($entry.supported_reasoning_levels // []) | map(.effort) | index($l)) != null then "supported"
      else "unsupported"
      end
  ' "$catalog" 2>/dev/null) || return 1
  [ "$result" = supported ] && return 0
  return 2
}
