#!/usr/bin/env bash
# Answer one question about the current git worktree: is this landing branch safe
# to start lane work from, and if not, why not.
# Usage: fm-lane-base-check.sh <landing-branch> [--publishes]
#   Runs in the current worktree and WRITES NOTHING: no reset, no fetch, no ref
#   update, no index change, and no lock taken - every git read here runs with
#   git's optional locks disabled, so not even `git status` can refresh the index
#   underneath a workspace Playbot is concurrently rewriting. It reports a verdict
#   and the caller acts on it.
#   bin/fm-brief.sh --lane renders this invocation as a lane brief's first action,
#   because Playbot creates a lane workspace from the REMOTE tip of the landing
#   branch, so a landing that has not been pushed yet leaves the workspace behind.
#   <landing-branch> is a plain local branch name. It is always compared as
#   refs/heads/<branch>: the remote ref is the one the workspace was created from
#   and so can never reveal that drift, and a bare name would also resolve through
#   refs/tags/ and refs/remotes/.
#   --publishes declares that this lane ships through a PR. A PR's base is the
#   landing branch AS PUBLISHED, so a commit that is on the local landing branch
#   but not on its remote tip would ride along in the PR as if it were the lane's
#   own work. Only with this flag is the local landing branch required to carry
#   nothing its remote tip lacks; a local-only lane publishes nothing, so its local
#   landing branch is the whole truth and no remote comparison applies.
# Verdicts are exit codes, so a caller branches on the code and never parses prose:
#   0   current: <evidence>          base is safe; proceed untouched
#   10  reset-required: <ref>        safe to reset, onto exactly that ref
#       churn-paths: <paths...>      allowlisted Playbot churn the reset would
#                                    discard, empty when the working tree is clean
#   20  blocked: <evidence>          not safe; one line naming the evidence
#   2   usage error (message on stderr)
# The named states, all of them:
#   current            HEAD is the landing tip.
#   ahead only         the landing tip is an ancestor of HEAD, which is what
#                      docs/playbot-lanes.md calls current: the lane's own commits,
#                      or the newer landing tip its workspace was created from.
#   behind only, clean tree                      reset-required, no churn paths.
#   behind only, allowlisted churn only          reset-required, naming those paths
#                                                (staged churn included).
#   behind only, anything outside the allowlist  blocked; uncommitted work outside
#                                                the allowlist is never discarded.
#   behind only, an UNTRACKED file at an allowlisted path
#                                                blocked, under its OWN reason and
#                      not the one above: the path is one the owner publishes, so
#                      what disqualifies it is that it is untracked. Churn is a
#                      tracked change - the allowlist's owner infers no untracked
#                      file to be churn, and `git diff HEAD` records nothing for
#                      content git does not track, so discarding one could only
#                      ever be announced with an empty record. A workspace holding
#                      both kinds is reported with both reasons.
#                      The untracked half of this gate is read with an explicit
#                      `--untracked-files=all`, so no `status.showUntrackedFiles`
#                      in the shared config can silence it: a verdict of this
#                      script never depends on operator configuration.
#   diverged                                     blocked.
#   absent local landing branch                  blocked.
#   --publishes and the local landing branch carries commits its remote tip lacks
#                      blocked, naming both commits. Strictly ahead: one push of
#                      the landing branch clears it. DIVERGED, each side carrying
#                      commits the other lacks: still blocked, but the remedy is to
#                      reconcile the landing branch with its remote tip first,
#                      because a plain push would be rejected as a non-fast-forward
#                      - the two states are told apart so neither is prescribed the
#                      other's command. A remote tip that is AHEAD ONLY of the local
#                      landing branch is not blocked - that is the state right after
#                      a PR merges, it carries no ride-along risk, and pushing could
#                      not fix it anyway.
#   --publishes and no remote tip resolvable     blocked; absence of evidence
#                      cannot prove nothing rides along. The ONLY evidence is a
#                      remote-tracking ref of the landing branch's own name, since
#                      that is the ref a PR would build on, so the candidates are
#                      refs/remotes/<remote>/<landing> and the configured upstream
#                      only picks between them - an upstream naming a local branch
#                      or a DIFFERENT remote branch resolves nothing. Each cause
#                      gets its own line, because each has its own remedy: no
#                      upstream and no such remote-tracking ref (fetch it, or push
#                      a landing branch never published); an upstream configured
#                      whose remote-tracking ref does not exist, deleted upstream
#                      and pruned or never fetched (fetch that branch); a local
#                      upstream; an upstream naming a different remote branch; and
#                      more than one remote carrying the landing branch's name
#                      with no upstream choosing one, which is ambiguous (name the
#                      one, with --set-upstream-to).
#   working tree unreadable                      blocked; a tree whose state
#                      cannot be read must never be reported as clean, because a
#                      clean tree is what authorises the reset.
# The tracked-churn allowlist is NOT defined here. It is read at run time from its
# owner, `bin/fm-playbot-lanes.mjs tracked-churn-allowlist`, so this script cannot
# drift from the list Playbot's own retirement inspection allows. When that list
# cannot be read, NO path is treated as churn: any modification then makes the
# workspace dirty and the verdict is blocked, because an unreadable owner must
# never widen what a reset is allowed to discard. That block names the unreadable
# allowlist as its cause and the remedy for the failure it hit - node absent, the
# owner file missing, or the owner command failing - and explicitly does NOT claim
# the paths are outside the allowlist, since nothing was compared.
# Membership is a whole-string comparison of a TRACKED change's pathname against
# those entries: no pattern, no line matching, no untracked file, and no prefix,
# extension or basename.
set -eu

# The contract above says this script changes no index, and `git status` is the
# one read that could: it may refresh the index's stat cache, rewrite .git/index
# opportunistically, and contend for .git/index.lock while doing so. A lane
# workspace is by this feature's own premise being rewritten concurrently by
# Playbot's editor, so that is the worst place to take a lock. Setting this once
# for the whole script rather than per call means the claim holds for every git
# invocation here, including any added later: git performs no optional
# sub-operation that would require a lock, and the verdicts are unchanged.
export GIT_OPTIONAL_LOCKS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

EXIT_CURRENT=0
EXIT_RESET_REQUIRED=10
EXIT_BLOCKED=20

LANDING=
PUBLISHES=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --publishes) PUBLISHES=1 ;;
    --*) echo "error: unknown option $arg" >&2; exit 2 ;;
    *)
      [ -z "$LANDING" ] || {
        echo "error: one landing branch only (got '$LANDING' and '$arg')" >&2
        exit 2
      }
      LANDING=$arg ;;
  esac
done
[ -n "$LANDING" ] || {
  echo "error: fm-lane-base-check.sh requires a landing branch" >&2
  exit 2
}

current() { printf 'current: %s\n' "$1"; exit "$EXIT_CURRENT"; }
blocked() { printf 'blocked: %s\n' "$1"; exit "$EXIT_BLOCKED"; }

# The allowlist's owner publishes it through its own command, so nothing here
# parses that file. A read failure leaves the list empty, which is the safe
# direction: every modification then counts against the workspace. But "the list
# is empty because it could not be read" is a different fact from "this path is
# not on the list", and only the first has a remedy, so each failure records which
# one it was. Runs in the main shell, not a command substitution, so that record
# survives.
CHURN_OWNER_UNREADABLE=
CHURN_ALLOWLIST=()
read_churn_allowlist() {
  local owner="$SCRIPT_DIR/fm-playbot-lanes.mjs" raw entry
  if ! command -v node >/dev/null 2>&1; then
    CHURN_OWNER_UNREADABLE="node is not on PATH, so its owner $owner could not be run; make node available"
    return 0
  fi
  if [ ! -f "$owner" ]; then
    CHURN_OWNER_UNREADABLE="its owner $owner is missing; restore that file"
    return 0
  fi
  if ! raw=$(node "$owner" tracked-churn-allowlist 2>/dev/null); then
    CHURN_OWNER_UNREADABLE="its owner command \`node $owner tracked-churn-allowlist\` failed; repair the owner so it prints the list"
    return 0
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    CHURN_ALLOWLIST+=("$entry")
  done <<EOF
$raw
EOF
}

# Whether one changed path IS an allowlisted path, compared as whole literal
# strings. This is the only test that authorises a discard, so it must never treat
# the pathname as a pattern or as a list of lines: `git status --porcelain -z`
# preserves a newline inside a pathname exactly, and a matcher that split on
# newlines would call `scratch<newline>prototype-game/project.godot` churn because
# one of its lines is an allowlisted entry. The `churn-paths:` line is
# space-separated, which is safe only because the owned paths carry no whitespace;
# an exact-match test is what keeps that a property of the data rather than luck.
# The allowlist names TRACKED paths Playbot's editor rewrites, and its owner is
# explicit that no untracked file is inferred to be churn. An untracked path also
# cannot be disclosed: `git diff HEAD -- <path>` shows nothing for content git does
# not track, so calling one churn would announce a discard with an empty record.
# Being untracked AT an allowlisted path is therefore its own outcome, not the same
# as being outside the list - the path IS one the owner publishes, and a blocked
# line that claimed otherwise would send its reader to check the allowlist, find it
# there, and conclude the check is broken.
CLASSIFICATION=
classify_changed_path() {
  local status=$1 candidate=$2 entry listed=0
  for entry in ${CHURN_ALLOWLIST[@]+"${CHURN_ALLOWLIST[@]}"}; do
    if [ "$candidate" = "$entry" ]; then
      listed=1
      break
    fi
  done
  case "$status" in
    '??'|'!!')
      if [ "$listed" -eq 1 ]; then
        CLASSIFICATION=untracked-at-allowlisted-path
      else
        CLASSIFICATION=outside
      fi
      return 0 ;;
  esac
  if [ "$listed" -eq 1 ]; then
    CLASSIFICATION=churn
  else
    CLASSIFICATION=outside
  fi
}

# Every path `git status` reports, into CHANGED_PATHS with its two-letter status
# field alongside in CHANGED_STATUS, NUL-separated on the way so a pathname with a
# space or a newline keeps its exact Git identity. The status is kept because what
# a path may be discarded for depends on it, not only on its name.
# A rename or copy record is `XY <path>NUL<origPath>NUL`: the source path follows
# as a bare record with no status field of its own, so it is taken whole and given
# the same status as the record that introduced it - it is that same change.
# The records go through a file rather than a pipeline or a process substitution
# because those discard `git status`'s exit status, and this is the one read whose
# failure would be read as a CLEAN tree - the state that authorises the reset. So
# it fails closed like every other read here, and the caller runs it in the main
# shell so that block takes effect.
# `--untracked-files=all` is passed EXPLICITLY, and that is load-bearing rather
# than decorative. Bare `git status` honours `status.showUntrackedFiles`, which
# lives in the shared config of the common git dir, so one `git config
# status.showUntrackedFiles no` in the primary repository would silence the
# untracked half of this gate in every lane worktree it hosts - and a silent gate
# reads as a clean tree, which is what authorises the reset. The flag overrides any
# ambient setting, and `all` rather than `normal` names each untracked file instead
# of collapsing it into its parent directory, so the evidence line can name the
# actual path. No verdict of this script may depend on operator configuration.
CHANGED_PATHS=()
CHANGED_STATUS=()
collect_changed_paths() {
  local record pending=0 status='' spool
  spool=$(mktemp) \
    || blocked "working-tree state of this lane workspace could not be read: no temporary file could be created to read it into"
  if ! git --no-optional-locks status --porcelain --untracked-files=all -z > "$spool" 2>/dev/null; then
    rm -f "$spool"
    blocked "working-tree state of this lane workspace could not be read, so no uncommitted work can be shown to be absent and nothing here is safe to discard"
  fi
  while IFS= read -r -d '' record; do
    if [ "$pending" -eq 1 ]; then
      pending=0
      CHANGED_STATUS+=("$status")
      CHANGED_PATHS+=("$record")
      continue
    fi
    status=${record:0:2}
    case "$status" in
      R?|C?|?R|?C) pending=1 ;;
    esac
    CHANGED_STATUS+=("$status")
    CHANGED_PATHS+=("${record:3}")
  done < "$spool"
  rm -f "$spool"
}

git rev-parse --git-dir >/dev/null 2>&1 || blocked "not a git worktree: $(pwd -P)"

LOCAL_REF="refs/heads/$LANDING"
LOCAL_TIP=$(git rev-parse --verify --quiet "$LOCAL_REF") || LOCAL_TIP=
[ -n "$LOCAL_TIP" ] || blocked "local landing branch $LANDING is missing from this repository"

if [ "$PUBLISHES" -eq 1 ]; then
  # The whole question is about ONE ref pair: does refs/remotes/<remote>/<landing>
  # exist, and does refs/heads/<landing> carry any commit it lacks. A PR's base is
  # the landing branch BY NAME - bin/fm-brief.sh renders it as --base - so only a
  # remote-tracking ref of that same name is evidence about what a PR would build
  # on. So the candidate tips are found by scanning the remotes for that exact
  # name, and NOTHING else can become the remote tip: the configured upstream is
  # consulted only to choose between candidates, because an upstream is free to
  # name a local branch (`branch.autoSetupMerge = always` does that routinely) or
  # a different remote branch, and neither says anything about this ref pair.
  UPSTREAM_REF=$(git rev-parse --symbolic-full-name --verify --quiet "$LANDING@{upstream}") \
    || UPSTREAM_REF=
  REMOTES=$(git remote) || blocked "the remotes of this repository could not be listed, so the published tip of landing branch $LANDING cannot be found"
  REMOTE_TIP=
  REMOTE_TIP_REF=
  REMOTE_MATCHES=0
  UPSTREAM_IS_CANDIDATE=0
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    candidate_ref="refs/remotes/$remote/$LANDING"
    candidate=$(git rev-parse --verify --quiet "$candidate_ref") || candidate=
    [ -n "$candidate" ] || continue
    REMOTE_MATCHES=$((REMOTE_MATCHES + 1))
    if [ "$candidate_ref" = "$UPSTREAM_REF" ]; then
      UPSTREAM_IS_CANDIDATE=1
      REMOTE_TIP=$candidate
      REMOTE_TIP_REF=$candidate_ref
    elif [ "$UPSTREAM_IS_CANDIDATE" -eq 0 ]; then
      REMOTE_TIP=$candidate
      REMOTE_TIP_REF=$candidate_ref
    fi
  done <<EOF
$REMOTES
EOF

  if [ "$REMOTE_MATCHES" -gt 1 ] && [ "$UPSTREAM_IS_CANDIDATE" -eq 0 ]; then
    # Every candidate ref exists here, so naming one is a remedy that works.
    blocked "remote tip of landing branch $LANDING could not be resolved: $REMOTE_MATCHES remotes carry a ref named refs/remotes/<remote>/$LANDING and no upstream of this branch names one of them, so which published tip a PR would build on is ambiguous; run git branch --set-upstream-to=<remote>/$LANDING $LANDING to name the one this lane lands on, so a lane that opens a PR can prove nothing rides along"
  fi

  if [ "$REMOTE_MATCHES" -eq 0 ]; then
    # No such ref exists, so --set-upstream-to would only fatal here: the branch
    # has to be fetched, or pushed if it was never published. Each cause is named
    # separately because a wrongly configured upstream is a different repair from
    # a missing one, and one of them has a more precise fetch to prescribe.
    UNRESOLVED_REMEDY="run git fetch --all to pick it up, or push $LANDING if it has never been published"
    case "$UPSTREAM_REF" in
      refs/remotes/*)
        UNRESOLVED_CAUSE="its upstream $UPSTREAM_REF names a different remote branch, which says nothing about the ref a PR would target" ;;
      refs/heads/*)
        UNRESOLVED_CAUSE="its upstream $UPSTREAM_REF is a local branch, which publishes nothing" ;;
      *)
        UPSTREAM_REMOTE=$(git config --get "branch.$LANDING.remote") || UPSTREAM_REMOTE=
        UPSTREAM_MERGE=$(git config --get "branch.$LANDING.merge") || UPSTREAM_MERGE=
        UPSTREAM_BRANCH=${UPSTREAM_MERGE#refs/heads/}
        [ -n "$UPSTREAM_BRANCH" ] || UPSTREAM_BRANCH=$LANDING
        if [ -n "$UPSTREAM_REMOTE" ] && [ "$UPSTREAM_REMOTE" != "." ]; then
          UNRESOLVED_CAUSE="an upstream of $UPSTREAM_REMOTE/$UPSTREAM_BRANCH is configured but the remote-tracking ref it names does not exist in this repository, so it was deleted upstream and pruned, or never fetched"
          UNRESOLVED_REMEDY="run git fetch $UPSTREAM_REMOTE $UPSTREAM_BRANCH to pick it up, or push $LANDING if it has never been published"
        else
          UNRESOLVED_CAUSE="it has no upstream configured"
        fi ;;
    esac
    blocked "remote tip of landing branch $LANDING could not be resolved: $UNRESOLVED_CAUSE, and no remote-tracking ref refs/remotes/<remote>/$LANDING exists; $UNRESOLVED_REMEDY, so a lane that opens a PR can prove nothing rides along"
  fi

  # Both directions in one read, because the remedy depends on the other one: a
  # local landing branch that is strictly AHEAD is fixed by pushing it, but one
  # that has DIVERGED cannot be - that push is rejected as a non-fast-forward, and
  # prescribing it would send the operator to a command that cannot work.
  PUBLISH_COUNTS=$(git rev-list --left-right --count "$LOCAL_REF...$REMOTE_TIP") \
    || blocked "distance between $LOCAL_REF and the remote tip $REMOTE_TIP_REF of landing branch $LANDING could not be read"
  read -r RIDE_ALONG REMOTE_ONLY <<EOF
$PUBLISH_COUNTS
EOF
  if [ "$RIDE_ALONG" -gt 0 ] && [ "$REMOTE_ONLY" -gt 0 ]; then
    blocked "landing branch $LANDING has diverged from its remote tip: local $LOCAL_TIP carries $RIDE_ALONG commit(s) its remote tip $REMOTE_TIP_REF ($REMOTE_TIP) does not while that tip carries $REMOTE_ONLY it lacks, and a PR based on that remote tip would present the local-only commits as this task's work; reconcile $LANDING with its remote tip and push the result before this lane proceeds - a plain push of $LANDING would be rejected as a non-fast-forward"
  fi
  [ "$RIDE_ALONG" -eq 0 ] || blocked "landing branch $LANDING is not published: local $LOCAL_TIP carries $RIDE_ALONG commit(s) its remote tip $REMOTE_TIP_REF ($REMOTE_TIP) does not, and a PR based on that remote tip would present them as this task's work; push $LANDING before this lane proceeds"
fi

COUNTS=$(git rev-list --left-right --count "$LOCAL_REF...HEAD") \
  || blocked "ahead/behind distance between $LOCAL_REF and HEAD could not be read"
read -r BEHIND AHEAD <<EOF
$COUNTS
EOF

if [ "$BEHIND" -eq 0 ] && [ "$AHEAD" -eq 0 ]; then
  current "HEAD is the tip of $LANDING ($LOCAL_TIP)"
fi
if [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -gt 0 ]; then
  blocked "lane workspace has diverged from landing branch $LANDING: $BEHIND commit(s) behind, $AHEAD of its own"
fi
if [ "$AHEAD" -gt 0 ]; then
  current "the tip of $LANDING ($LOCAL_TIP) is an ancestor of HEAD, which is $AHEAD commit(s) ahead of it"
fi

read_churn_allowlist

CHURN_MODIFIED=
OUTSIDE=
UNTRACKED_LISTED=
collect_changed_paths
for ((i = 0; i < ${#CHANGED_PATHS[@]}; i++)); do
  path=${CHANGED_PATHS[$i]}
  [ -n "$path" ] || continue
  classify_changed_path "${CHANGED_STATUS[$i]}" "$path"
  case "$CLASSIFICATION" in
    churn) CHURN_MODIFIED="${CHURN_MODIFIED:+$CHURN_MODIFIED }$path" ;;
    untracked-at-allowlisted-path)
      UNTRACKED_LISTED="${UNTRACKED_LISTED:+$UNTRACKED_LISTED, }$path" ;;
    *) OUTSIDE="${OUTSIDE:+$OUTSIDE, }$path" ;;
  esac
done

# Both reasons are reported, because a workspace can carry one of each and the
# verdict is one line of evidence a human and firstmate act on directly.
EVIDENCE=
if [ -n "$OUTSIDE" ] && [ -n "$CHURN_OWNER_UNREADABLE" ]; then
  # Nothing was compared against anything, so claiming these paths are outside the
  # allowlist would be the opposite of the truth - some of them may well be on it.
  blocked "lane workspace is behind landing branch $LANDING and carries uncommitted changes, but the Playbot churn allowlist could not be read, so nothing here can be shown to be safe to discard and none of these paths is claimed to be outside that allowlist: $OUTSIDE; $CHURN_OWNER_UNREADABLE"
fi
[ -z "$OUTSIDE" ] || EVIDENCE="uncommitted changes outside the Playbot churn allowlist: $OUTSIDE"
if [ -n "$UNTRACKED_LISTED" ]; then
  EVIDENCE="${EVIDENCE:+$EVIDENCE; and }untracked files at allowlisted churn paths, which are never classified as churn because git diff HEAD records nothing for content git does not track, so they could only be discarded unseen: $UNTRACKED_LISTED (commit or remove them)"
fi
[ -z "$EVIDENCE" ] || blocked "lane workspace is behind landing branch $LANDING but carries $EVIDENCE"

printf 'reset-required: %s\n' "$LOCAL_REF"
printf 'churn-paths: %s\n' "$CHURN_MODIFIED"
exit "$EXIT_RESET_REQUIRED"
