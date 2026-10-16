#!/usr/bin/env bash
# Shared contract for a ship brief's open design-question dependencies.
# A project may keep a register of unresolved design questions. A ship brief for
# such a project is scaffolded by bin/fm-brief.sh, which emits this section for
# firstmate to fill before dispatch (`--open-questions <register>` declares it for
# a project the registry does not):
#   # Open-question dependencies
#   Open-question register: <register path relative to the project root>
#   {OPEN_QUESTION_DEPENDENCIES}
# The placeholder is replaced with one line per register question the work
# depends on, in exactly one of these forms:
#   Open question <id>: open
#   Open question <id>: resolved <YYYY-MM-DD>: <where the answer is recorded>
#   Open question <id>: provisional default authorized <YYYY-MM-DD>: <scoped default>
# or with the single line `Open questions: none` when the work depends on none.
# An <id> is the register's own identifier (letters, digits, '.', '_', '-').
# A provisional default names the default and the scope it is authorized for; its
# date is when that authorization was given. Dates are real calendar days no
# later than the dispatch day.
# Only lines inside that section, up to the next top-level heading outside a fenced
# block, are read; task text and the captain's intent never count.
# A project whose data/projects.md entry declares a register (see
# bin/fm-project-mode.sh) gets the section from bin/fm-brief.sh automatically, and
# bin/fm-spawn.sh refuses fresh ship dispatch when the section is missing or names
# a register that project did not declare.
# bin/fm-spawn.sh refuses fresh dispatch of a brief that declares a register while
# the placeholder remains, a line is malformed or duplicated, `none` is mixed with
# dependency lines, or any named question is still `open`. After the dispatch
# worktree is on its landing base, it also refuses when the register file is
# absent there or a named <id> does not appear in it. Relaunches preserve work
# and do not repeat the dispatch check.
# The register's prose stays free-form, so whether a question is resolved is
# firstmate's recorded judgment; this check binds that judgment to every named
# question and to the register the worker will read.

FM_OQ_PLACEHOLDER='{OPEN_QUESTION_DEPENDENCIES}'

FM_OQ_HEADING='# Open-question dependencies'

# Print the lines of the brief's dependency section: from its heading to the next
# top-level heading outside a fenced block, so task text and the captain's intent
# never count as dependency lines.
fm_oq_section() { # <brief>
  awk -v heading="$FM_OQ_HEADING" '
    /^(```|~~~)/ { fence = !fence }
    !fence && /^# / { in_section = ($0 == heading); next }
    in_section { print }
  ' "$1"
}

# Return 0 when the brief carries the dependency section.
fm_oq_brief_declares() { # <brief>
  [ -f "$1" ] && grep -qxF "$FM_OQ_HEADING" "$1"
}

fm_oq_valid_date() { # <YYYY-MM-DD> <today YYYY-MM-DD>
  local d=$1 today=$2 y m day max
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  y=$((10#${d%%-*}))
  m=${d#*-}
  m=$((10#${m%%-*}))
  day=$((10#${d##*-}))
  case "$m" in
    1|3|5|7|8|10|12) max=31 ;;
    4|6|9|11) max=30 ;;
    2)
      if { [ $((y % 4)) -eq 0 ] && [ $((y % 100)) -ne 0 ]; } || [ $((y % 400)) -eq 0 ]; then
        max=29
      else
        max=28
      fi
      ;;
    *) return 1 ;;
  esac
  [ "$day" -ge 1 ] && [ "$day" -le "$max" ] || return 1
  [ "$d" \< "$today" ] || [ "$d" = "$today" ]
}

# Validate the declared dependency section. Sets FM_OQ_REGISTER and FM_OQ_IDS
# (newline-separated named ids). Prints one error per problem and returns 1 when
# dispatch must be refused.
fm_oq_brief_check() { # <brief> <today YYYY-MM-DD>
  local brief=$1 today=$2 line rest id disposition registers=0 none=0 deps=0 bad=0 open_ids=''
  FM_OQ_REGISTER=
  FM_OQ_IDS=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'Open-question register:'*)
        registers=$((registers + 1))
        FM_OQ_REGISTER=$(printf '%s' "${line#Open-question register:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        ;;
      *"$FM_OQ_PLACEHOLDER"*)
        echo "error: $brief still contains $FM_OQ_PLACEHOLDER; name every open question the work depends on, or write 'Open questions: none'" >&2
        bad=1
        ;;
      'Open questions: none')
        none=1
        ;;
      'Open question '*)
        rest=${line#Open question }
        id=${rest%%:*}
        disposition=${rest#*:}
        disposition=${disposition# }
        if [ "$id" = "$rest" ] || [ -z "$id" ] || ! printf '%s' "$id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
          echo "error: malformed open-question line in $brief: $line" >&2
          bad=1
          continue
        fi
        if printf '%s' "$FM_OQ_IDS" | grep -Fqx -- "$id"; then
          echo "error: open question $id is named more than once in $brief" >&2
          bad=1
          continue
        fi
        FM_OQ_IDS="${FM_OQ_IDS}${id}"$'\n'
        deps=$((deps + 1))
        case "$disposition" in
          open)
            open_ids="${open_ids} $id"
            ;;
          'resolved '*|'provisional default authorized '*)
            rest=${disposition#resolved }
            [ "$rest" != "$disposition" ] || rest=${disposition#provisional default authorized }
            if ! fm_oq_valid_date "${rest%%:*}" "$today"; then
              echo "error: open question $id needs a real date no later than $today in $brief: $line" >&2
              bad=1
            elif [ -z "$(printf '%s' "${rest#*:}" | tr -d '[:space:]')" ] || [ "${rest#*:}" = "$rest" ]; then
              echo "error: open question $id must say where the answer is recorded or which scoped default is authorized in $brief: $line" >&2
              bad=1
            fi
            ;;
          *)
            echo "error: malformed open-question disposition in $brief: $line" >&2
            bad=1
            ;;
        esac
        ;;
    esac
  done <<EOF
$(fm_oq_section "$brief")
EOF
  if [ "$registers" -ne 1 ] || [ -z "$FM_OQ_REGISTER" ]; then
    echo "error: $brief must declare exactly one non-empty Open-question register line" >&2
    bad=1
  else
    case "/$FM_OQ_REGISTER/" in
      //*|*/../*) echo "error: open-question register must be a path inside the project: $FM_OQ_REGISTER" >&2; bad=1 ;;
    esac
  fi
  if [ "$none" -eq 1 ] && [ "$deps" -gt 0 ]; then
    echo "error: $brief says 'Open questions: none' and also names open questions" >&2
    bad=1
  elif [ "$none" -eq 0 ] && [ "$deps" -eq 0 ] && [ "$bad" -eq 0 ]; then
    echo "error: $brief names no open-question dependency; list each one or write 'Open questions: none'" >&2
    bad=1
  fi
  if [ -n "$open_ids" ]; then
    echo "error: the work depends on still-open design question(s):$open_ids; resolve each, or record a scoped provisional default with its authorization date, before dispatch" >&2
    bad=1
  fi
  [ "$bad" -eq 0 ]
}

# Check the declared register against the dispatch worktree after
# fm_oq_brief_check succeeded.
fm_oq_register_check() { # <worktree>
  local wt=$1 file id pattern bad=0
  file="$wt/$FM_OQ_REGISTER"
  [ -f "$file" ] || {
    echo "error: open-question register $FM_OQ_REGISTER is not present on the dispatch base" >&2
    return 1
  }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    pattern=$(printf '%s' "$id" | sed 's/\./\\./g')
    grep -Eq "(^|[^A-Za-z0-9._-])${pattern}([^A-Za-z0-9_-]|$)" "$file" || {
      echo "error: open question $id does not appear in register $FM_OQ_REGISTER on the dispatch base" >&2
      bad=1
    }
  done <<EOF
$FM_OQ_IDS
EOF
  [ "$bad" -eq 0 ]
}
