#!/usr/bin/env bash
# Shared delivery for worker gates and completed jobs.
# fm_worker_doorbell_send <task> <message> persists a failure episode keyed by
# task and message, retries after 30 seconds doubling to 300, and queues just
# one supervisor wake until delivery succeeds. Returns 75 while retrying.
# STATE/worker-doorbells/<sha256>.failure stores: next-epoch delay-seconds notified.
# Successful delivery removes that episode; the inbox owns success deduplication.
# The per-key lock serializes delivery and the wake/state publication.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_worker_doorbell_send() {
  local task=$1 message=$2 digest dir lock record now next=0 delay=30 notified=0 tmp rc=0
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s\n%s\n' "$task" "$message" | sha256sum | cut -d ' ' -f1) || return 1
  else
    digest=$(printf '%s\n%s\n' "$task" "$message" | shasum -a 256 | cut -d ' ' -f1) || return 1
  fi
  dir=$STATE/worker-doorbells
  mkdir -p "$dir" || return 1
  lock=$dir/$digest.lock
  record=$dir/$digest.failure
  fm_lock_acquire_wait "$lock" || return 1
  if [ -f "$record" ]; then
    read -r next delay notified < "$record" || true
  fi
  now=$(date +%s)
  if [ "$now" -lt "$next" ]; then
    fm_lock_release "$lock"
    return 75
  fi
  if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 \
    "$SCRIPT_DIR/fm-send.sh" "$task" "$message" >/dev/null 2>&1; then
    rm -f "$record"
  else
    # Keep wake acknowledgement excluded until the failure record is durable.
    # After a crash between append and record publication, the retained queue
    # row proves the wake already exists and prevents another append.
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || { fm_lock_release "$lock"; return 1; }
    if [ "$notified" -eq 0 ]; then
      if { [ -f "$FM_WAKE_QUEUE" ] && awk -F '\t' -v key="worker-doorbell:$digest" '$4 == key { found=1 } END { exit !found }' "$FM_WAKE_QUEUE"; } \
        || fm_wake_append_locked check "worker-doorbell:$digest" "check: worker-doorbell delivery failed for $task: $message"; then
        notified=1
      else
        rc=1
      fi
    fi
    tmp=$(mktemp "$dir/.failure.XXXXXX") || rc=1
    if [ -n "$tmp" ]; then
      printf '%s %s %s\n' "$((now + delay))" "$((delay < 150 ? delay * 2 : 300))" "$notified" > "$tmp" && mv "$tmp" "$record" || rc=1
      rm -f "$tmp"
    fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    [ "$rc" -ne 0 ] || rc=75
  fi
  fm_lock_release "$lock"
  return "$rc"
}
