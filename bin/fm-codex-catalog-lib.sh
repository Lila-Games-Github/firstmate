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
# fm_codex_model_supports_level_json <level>
#   Prints a JSON array of every catalog model slug whose
#   supported_reasoning_levels lists <level>, always returning 0. A missing,
#   unreadable, or invalid catalog, or no jq on PATH, prints [] - an
#   unverifiable answer is deliberately indistinguishable from a verified-empty
#   one, so a membership test never accepts a model it could not confirm.
#
# config/crew-dispatch.json's bootstrap linter (bin/fm-bootstrap.sh), the
# typed-dispatch resolver (bin/fm-dispatch-resolve.sh), and the spawn
# (bin/fm-spawn.sh) all read this same catalog for codex max.

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

fm_codex_model_supports_level_json() {  # <level>
  local level=$1 catalog result
  catalog=$(fm_codex_catalog_path)
  if command -v jq >/dev/null 2>&1 && [ -r "$catalog" ] \
    && result=$(jq -c --arg l "$level" '
      [(.models // [])[] | select((.supported_reasoning_levels // []) | map(.effort) | index($l)) | .slug]
    ' "$catalog" 2>/dev/null) && [ -n "$result" ]; then
    printf '%s\n' "$result"
  else
    printf '[]\n'
  fi
  return 0
}
