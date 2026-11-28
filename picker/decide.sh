#!/usr/bin/env bash
# The runner picker's decision (ADR 0004 in the owner's pc-hardening repo).
#
#   1. A fork pull request or a deploy job goes to the fallback runner.
#   2. A forced choice (for validating a repo) is followed.
#   3. If the pool's status can't be read, the fallback.
#   4. If no pool runner is online, the fallback.
#   5. If a pool runner is idle, the pool.
#   6. Every pool runner busy: the pool (the job waits), unless overflow mode is on,
#      then the fallback.
#
# The fallback is GitHub-hosted (ubuntu-latest) for a public repo and Ubicloud for a private
# one. A repo whose visibility is unknown counts as private. The Ubicloud size is --repo-size (the
# repo's CI_FALLBACK_SIZE) when given, else the settings file's fallback_size, else
# ubicloud-standard-2; a value that isn't a Ubicloud label gives ubicloud-standard-2 and says why.
# Overflow mode comes from --repo-overflow (on|off) when given, else from the settings file
# ({"overflow": "on"}); anything unreadable counts as off.
#
# Usage:
#   decide.sh --visibility public|private --fork true|false --deploy true|false
#             (--runners FILE | --runners-error MESSAGE)
#             [--settings FILE] [--repo-overflow on|off] [--repo-size LABEL] [--force pool|fallback]
#
# FILE is a response from GET /orgs/{org}/actions/runners. Pool runners carry the label home-wsl.
# Prints GITHUB_OUTPUT lines: choice, runner (JSON for fromJSON), pool, fallback, reason, overflow,
# fallback_size (the label and where it came from).
set -euo pipefail

POOL_LABEL=home-wsl
DEFAULT_SIZE=ubicloud-standard-2
UBICLOUD_LABEL='^ubicloud-[a-z0-9]+(-[a-z0-9]+)*$'
visibility='' fork=false deploy=false runners='' runners_error='' settings=''
repo_overflow='' repo_size='' force=''

while [ $# -gt 0 ]; do
  case $1 in
    --visibility) visibility=$2 ;;
    --fork) fork=$2 ;;
    --deploy) deploy=$2 ;;
    --runners) runners=$2 ;;
    --runners-error) runners_error=$2 ;;
    --settings) settings=$2 ;;
    --repo-overflow) repo_overflow=$2 ;;
    --repo-size) repo_size=$2 ;;
    --force) force=$2 ;;
    *) echo "decide.sh: unknown argument $1" >&2; exit 2 ;;
  esac
  shift 2
done
case $force in ''|pool|fallback) ;; *) echo "decide.sh: --force must be pool or fallback, not '$force'" >&2; exit 2 ;; esac

# ci-shared's settings file, if it's JSON. Missing or not JSON: unreadable.
settings_ok=false
if [ -n "$settings" ] && [ -r "$settings" ] && jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
  settings_ok=true
fi

# A private repo's Ubicloud size: the repo's, else ci-shared's, else the built-in one.
size_from=built-in
if [ -n "$repo_size" ]; then
  if [[ "$repo_size" =~ $UBICLOUD_LABEL ]]; then size=$repo_size; size_from=repo
  else size=$DEFAULT_SIZE; size_from="built-in; the repo's CI_FALLBACK_SIZE '$repo_size' isn't a Ubicloud label"; fi
elif ! $settings_ok; then
  size=$DEFAULT_SIZE; size_from="built-in; ci-shared's settings unreadable"
else
  central=$(jq -r 'if has("fallback_size") then (.fallback_size | tostring) else empty end' "$settings")
  if [ -z "$central" ]; then size=$DEFAULT_SIZE
  elif [[ "$central" =~ $UBICLOUD_LABEL ]]; then size=$central; size_from=ci-shared
  else size=$DEFAULT_SIZE; size_from="built-in; ci-shared's fallback_size '${central:0:40}' isn't a Ubicloud label"; fi
fi

pool_runner="[\"self-hosted\",\"$POOL_LABEL\"]"
if [ "$visibility" = public ]; then
  fallback_runner='"ubuntu-latest"'; fallback_name='GitHub-hosted ubuntu-latest'
  size_line="ubuntu-latest (public repo)"
else
  fallback_runner="\"$size\""; fallback_name="$size ($size_from)"
  size_line="$size ($size_from)"
fi

# Overflow mode: the repo's override, else ci-shared's settings file, else off.
case $repo_overflow in
  on|off) overflow=$repo_overflow; overflow_from=repo ;;
  *)
    overflow=off; overflow_from=ci-shared
    if $settings_ok; then
      value=$(jq -r '.overflow // empty' "$settings" 2>/dev/null || true)
      if [ "$value" = on ]; then overflow=on
      elif [ "$value" != off ]; then overflow_from="ci-shared, unreadable"
      fi
    else
      overflow_from="ci-shared, unreadable"
    fi ;;
esac

choose() { # choose pool|fallback REASON
  echo "choice=$1"
  if [ "$1" = pool ]; then echo "runner=$pool_runner"; echo "pool=true"
  else echo "runner=$fallback_runner"; echo "pool=false"; fi
  echo "fallback=$fallback_runner"
  echo "overflow=$overflow"
  echo "fallback_size=$size_line"
  echo "reason=$2"
  exit 0
}
to_fallback() { choose fallback "$1; fallback is $fallback_name"; }

[ "$fork" = true ] && to_fallback "a pull request from a fork never runs on the pool"
[ "$deploy" = true ] && to_fallback "a deploy job never runs on the pool"
[ "$force" = fallback ] && to_fallback "forced onto the fallback by the caller"
[ "$force" = pool ] && choose pool "forced onto the pool by the caller (waits for a pool runner)"

# Pool status from the runner-list response.
if [ -n "$runners_error" ]; then
  to_fallback "couldn't read the pool's status ($runners_error)"
fi
if ! counts=$(jq -er --arg label "$POOL_LABEL" '
      [.runners[] | select(any(.labels[]; .name == $label)) | select(.status == "online")]
      | "\(length) \(map(select(.busy | not)) | length)"' "$runners" 2>/dev/null); then
  message=$(jq -r '.message // empty' "$runners" 2>/dev/null || true)
  [ -n "$message" ] || message="the response is not a runner list"
  to_fallback "couldn't read the pool's status ($message)"
fi
read -r online idle <<<"$counts"
registered=$(jq --arg label "$POOL_LABEL" '[.runners[] | select(any(.labels[]; .name == $label))] | length' "$runners")

[ "$online" -eq 0 ] && to_fallback "the pool is offline (0 of $registered pool runners online)"
[ "$idle" -gt 0 ] && choose pool "$idle of $online pool runners idle"
if [ "$overflow" = on ]; then
  to_fallback "all $online pool runners busy and overflow mode on ($overflow_from)"
fi
choose pool "all $online pool runners busy; the job waits for one (overflow mode off ($overflow_from))"
