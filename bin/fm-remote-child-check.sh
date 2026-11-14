#!/usr/bin/env bash
# Parent heartbeat check of every registered remote secondmate's live children.
# Usage: fm-remote-child-check.sh scan
# FM_REMOTE_CHILD_STALL_SECS defaults to 2700 (45 minutes).
# Notices only; this command never controls a remote endpoint.
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
BOUND=${FM_REMOTE_CHILD_STALL_SECS:-2700}
case "$BOUND" in ''|*[!0-9]*|0) echo 'remote-child-check: invalid stall bound' >&2; exit 2 ;; esac
[ "$BOUND" -ge 60 ] && [ "$BOUND" -le 86400 ] || { echo 'remote-child-check: stall bound must be 60..86400' >&2; exit 2; }
[ "${1:-}" = scan ] && [ "$#" -eq 1 ] || exit 2
[ -f "$DATA/secondmates.md" ] && [ ! -L "$DATA/secondmates.md" ] || exit 0
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
mkdir -p "$STATE/remote-child-check" || exit 1
[ ! -L "$STATE/remote-child-check" ] || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '- '*) ;; *) continue ;; esac
  secondmate_registry_parse_line "$line" || continue
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
  id=$SECONDMATE_REGISTRY_ID
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
  cursor="$STATE/remote-replies/$id.cursor"
  if [ -f "$cursor" ] && [ ! -L "$cursor" ]; then
    ack_offset=$(sed -n 's/^offset=//p' "$cursor" | head -1)
    ack_hash=$(sed -n 's/^prefix_sha256=//p' "$cursor" | head -1)
    case "$ack_offset:$ack_hash" in
      *[!0-9a-fA-F:]*|:*|*:) ;;
      *)
        if [ "${#ack_hash}" -eq 64 ]; then
          fm_run_timed 15 "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-parent-ack.sh "$ack_offset" "$ack_hash" >/dev/null 2>&1 || true
        fi
        ;;
    esac
  fi
  result=$(fm_run_timed 15 "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-child-inventory.sh 2>/dev/null) || result=
  if ! printf '%s' "$result" | jq -e '.schema == "fm-remote-child-inventory.v1" and .status == "ok" and (.children | type == "array" and length <= 64)' >/dev/null 2>&1; then
    verdict='unknown: live child inventory unavailable; remote host or read state is unknown'
    signature=unknown
  else
    verdict=
    signature=
    pending=$(printf '%s' "$result" | jq -r '.parent_channel_unacked_bytes // 0')
    case "$pending" in ''|*[!0-9]*) pending=0 ;; esac
    if [ "$pending" -gt 0 ]; then
      verdict="parent channel awaiting acknowledgement: ${pending} bytes remain in remote log"
      signature="pending:$pending"
    fi
    pr_reads=0
    while IFS= read -r child; do
      [ -n "$child" ] || continue
      cid=$(printf '%s' "$child" | jq -r '.id')
      cstate=$(printf '%s' "$child" | jq -r '.state')
      source=$(printf '%s' "$child" | jq -r '.source')
      age=$(printf '%s' "$child" | jq -r '.age_seconds')
      progress=$(printf '%s' "$child" | jq -r '.progress_epoch')
      pr=$(printf '%s' "$child" | jq -r '.pr')
      detail=$(printf '%s' "$child" | jq -r '.detail' | tr '\t\r\n' '   ' | cut -c1-250)
      case "$cid" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
      case "$age" in ''|*[!0-9]*) continue ;; esac
      case "$cstate" in
        blocked|failed) reason=$cstate ;;
        working|parked|unknown|paused) if [ "$age" -ge "$BOUND" ]; then reason=stalled; else reason=; fi ;;
        *) reason= ;;
      esac
      # gh-axi reports a numeric failed-check count in its summary. A failed
      # forge read is unknown; it cannot turn the PR red by itself.
      case "$pr" in
        https://github.com/*/*/pull/*)
          if [ "$pr_reads" -lt 8 ]; then
            pr_reads=$((pr_reads + 1))
            pr_path=${pr#https://github.com/}
            pr_repo=${pr_path%/pull/*}
            pr_num=${pr_path##*/}
            case "$pr_repo" in
              ''|*[!A-Za-z0-9._/-]*) ;;
              *)
                case "$pr_num" in
                  ''|*[!0-9]*) ;;
                  *)
                    pr_checks=$(fm_run_timed 8 "${FM_REMOTE_CHILD_GH_AXI_BIN:-gh-axi}" pr checks "$pr_num" -R "$pr_repo" 2>/dev/null) || pr_checks=
                    if printf '%s\n' "$pr_checks" | grep -Eq '(^|[^0-9])[1-9][0-9]* failed([^a-z]|$)'; then
                      reason='pr-red'
                      detail="PR checks red; $detail"
                    fi
                    ;;
                esac
                ;;
            esac
          fi
          ;;
      esac
      if [ -n "$reason" ]; then
        item="child=$cid state=$cstate reason=$reason age=${age}s source=$source progress_epoch=$progress detail=$detail"
        [ -z "$pr" ] || item="$item pr=$pr"
        verdict="${verdict}${verdict:+$'\n'}${item}"
        signature="${signature}${signature:+;}${cid}:${reason}:${progress}"
      fi
    done < <(printf '%s' "$result" | jq -c '.children[]')
  fi
  marker="$STATE/remote-child-check/$id.signature"
  [ ! -L "$marker" ] || continue
  if [ -z "$signature" ]; then
    rm -f "$marker"
    continue
  fi
  [ "$(cat "$marker" 2>/dev/null)" != "$signature" ] || continue
  first_notice=
  while IFS= read -r notice || [ -n "$notice" ]; do
    [ -n "$notice" ] || continue
    notice="remote secondmate $id: $notice"
    fm_wake_append check "remote-child:$id" "$notice" || exit 1
    [ -n "$first_notice" ] || first_notice=$notice
  done <<EOF
$verdict
EOF
  tmp=$(mktemp "$STATE/remote-child-check/.signature.XXXXXX") || exit 1
  printf '%s\n' "$signature" > "$tmp" || exit 1
  mv -f "$tmp" "$marker" || exit 1
  printf '%s\n' "$first_notice"
done < "$DATA/secondmates.md"
