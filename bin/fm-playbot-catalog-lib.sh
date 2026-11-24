#!/usr/bin/env bash
# Validate configured Playbot dispatch profiles against the catalog read by
# fm-playbot-lanes.mjs. Prints one error and returns 1 on invalid input.
fm_playbot_profiles_error() {
  local file=$1 catalog_home catalog err
  if ! jq -e '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [(.rules // [])[]? | profiles(.use)[]?, profiles(.default // null)[]?] | any(.surface? == "playbot")
  ' "$file" >/dev/null; then
    return 0
  fi
  catalog_home=${PLAYBOT_HARNESS_HOME:-$HOME/.playbot/harness}
  catalog="$catalog_home/playbot-model-catalog.json"
  if ! jq -e '.models | type == "array"' "$catalog" >/dev/null 2>&1; then
    printf 'Playbot model catalog unreadable or malformed: %s\n' "$catalog"
    return 1
  fi
  if ! err=$(jq -r --slurpfile catalog "$catalog" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [(.rules // [])[]? | profiles(.use)[]?, profiles(.default // null)[]?]
    | map(select(.surface? == "playbot"))
    | map(. as $p | ($catalog[0].models | map(select(.slug == $p.model and .visibility != "hide")) | first) as $m |
        if $m == null then "unknown Playbot model: \($p.model)"
        elif ($p.effort | type) != "string" or
             ([$m.supported_reasoning_levels[]? | if type == "string" then . else .effort end] | index($p.effort)) == null
        then "unsupported Playbot effort: \($p.model)/\($p.effort)"
        else empty end) | first // empty
  ' "$file" 2>/dev/null); then
    printf 'Playbot model catalog validation failed: %s\n' "$catalog"
    return 1
  fi
  [ -z "$err" ] && return 0
  printf '%s\n' "$err"
  return 1
}
