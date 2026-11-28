#!/usr/bin/env bash
# Seam 2: the runner picker's decision, run against saved runner-list responses.
# Each case gives decide.sh what a job would see and checks where the job goes and why.
# Usage: picker/tests/test-decide.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
decide=$here/../decide.sh
R=$here/responses
S=$here/settings

POOL='["self-hosted","home-wsl"]'
GITHUB='"ubuntu-latest"'
UBICLOUD='"ubicloud-standard-2"'

pass=0 fail=0

# check NAME EXPECTED_RUNNER REASON_SUBSTRING -- decide.sh arguments...
check() {
  local name=$1 want=$2 why=$3; shift 4
  local out runner reason
  out=$("$decide" "$@" 2>&1)
  runner=$(sed -n 's/^runner=//p' <<<"$out")
  reason=$(sed -n 's/^reason=//p' <<<"$out")
  if [ "$runner" = "$want" ] && [[ "$reason" == *"$why"* ]]; then
    pass=$((pass + 1)); echo "ok   $name"
  else
    fail=$((fail + 1))
    echo "FAIL $name"
    echo "     want runner $want, reason containing \"$why\""
    echo "     got  runner $runner, reason \"$reason\""
    sed 's/^/     | /' <<<"$out"
  fi
}

pub=(--visibility public --fork false --deploy false)
priv=(--visibility private --fork false --deploy false)

echo "# Idle pool"
check "public, idle pool -> pool"                 "$POOL" "2 of 6 pool runners idle" -- "${pub[@]}"  --runners "$R/idle.json"
check "private, idle pool -> pool"                "$POOL" "idle"                     -- "${priv[@]}" --runners "$R/idle.json"
check "idle pool, overflow on -> pool"            "$POOL" "idle"                     -- "${pub[@]}"  --runners "$R/idle.json" --settings "$S/overflow-on.json"

echo "# All busy"
check "public, all busy, overflow off -> pool (waits)"  "$POOL"     "waits"           -- "${pub[@]}"  --runners "$R/all-busy.json" --settings "$S/overflow-off.json"
check "private, all busy, overflow off -> pool (waits)" "$POOL"     "waits"           -- "${priv[@]}" --runners "$R/all-busy.json" --settings "$S/overflow-off.json"
check "public, all busy, overflow on -> GitHub-hosted"  "$GITHUB"   "overflow mode"   -- "${pub[@]}"  --runners "$R/all-busy.json" --settings "$S/overflow-on.json"
check "private, all busy, overflow on -> Ubicloud"      "$UBICLOUD" "overflow mode"   -- "${priv[@]}" --runners "$R/all-busy.json" --settings "$S/overflow-on.json"
check "busy online runners, rest offline, overflow off -> pool" "$POOL" "waits"       -- "${pub[@]}"  --runners "$R/busy-and-offline.json"
check "all busy, no settings given -> pool (off)"       "$POOL"     "waits"           -- "${pub[@]}"  --runners "$R/all-busy.json"

echo "# Overflow setting unreadable or overridden"
check "all busy, settings not JSON -> off -> pool"      "$POOL"     "waits"           -- "${pub[@]}"  --runners "$R/all-busy.json" --settings "$S/not-json.txt"
check "all busy, settings garbled -> off -> pool"       "$POOL"     "waits"           -- "${pub[@]}"  --runners "$R/all-busy.json" --settings "$S/overflow-garbled.json"
check "all busy, settings file missing -> off -> pool"  "$POOL"     "waits"           -- "${pub[@]}"  --runners "$R/all-busy.json" --settings "$S/does-not-exist.json"
check "all busy, org off, repo on -> fallback"          "$GITHUB"   "overflow mode on (repo)" -- "${pub[@]}" --runners "$R/all-busy.json" --settings "$S/overflow-off.json" --repo-overflow on
check "all busy, org on, repo off -> pool"              "$POOL"     "overflow mode off (repo)" -- "${pub[@]}" --runners "$R/all-busy.json" --settings "$S/overflow-on.json" --repo-overflow off
check "all busy, org on, repo blank -> fallback"        "$GITHUB"   "overflow mode on (ci-shared)" -- "${pub[@]}" --runners "$R/all-busy.json" --settings "$S/overflow-on.json" --repo-overflow ""

echo "# Offline pool"
check "public, pool offline -> GitHub-hosted"           "$GITHUB"   "offline"         -- "${pub[@]}"  --runners "$R/offline.json"
check "private, pool offline -> Ubicloud"               "$UBICLOUD" "offline"         -- "${priv[@]}" --runners "$R/offline.json"
check "private, pool offline, overflow on -> Ubicloud"  "$UBICLOUD" "offline"         -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/overflow-on.json"
check "private, no runners registered -> Ubicloud"      "$UBICLOUD" "offline"         -- "${priv[@]}" --runners "$R/no-runners.json"
check "only non-pool runners online -> fallback"        "$GITHUB"   "offline"         -- "${pub[@]}"  --runners "$R/only-other-runners.json"
check "visibility missing -> treated as private"        "$UBICLOUD" "offline"         -- --visibility "" --fork false --deploy false --runners "$R/offline.json"

echo "# Fallback size: the repo's CI_FALLBACK_SIZE, else ci-shared's fallback_size, else ubicloud-standard-2"
U8='"ubicloud-standard-8"' U4='"ubicloud-standard-4"'
check "private, offline, central size 8 -> 8"            "$U8"       "ubicloud-standard-8 (ci-shared)" -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/size-8.json"
check "private, overflow on, all busy, central 8 -> 8"   "$U8"       "overflow mode on"  -- "${priv[@]}" --runners "$R/all-busy.json" --settings "$S/overflow-on-size-8.json"
check "private, central 8, repo 4 -> 4"                  "$U4"       "ubicloud-standard-4 (repo)" -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/size-8.json" --repo-size ubicloud-standard-4
check "private, central 8, repo blank -> 8"              "$U8"       "(ci-shared)"     -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/size-8.json" --repo-size ""
check "private, no central size, repo 4 -> 4"            "$U4"       "(repo)"          -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/overflow-off.json" --repo-size ubicloud-standard-4
check "private, no central size -> built-in 2"           "$UBICLOUD" "ubicloud-standard-2 (built-in)" -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/overflow-off.json"
check "private, settings unreadable -> built-in 2"       "$UBICLOUD" "ci-shared's settings unreadable" -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/not-json.txt"
check "private, settings missing -> built-in 2"          "$UBICLOUD" "ci-shared's settings unreadable" -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/does-not-exist.json"
check "private, central size invalid -> built-in, why"   "$UBICLOUD" "isn't a Ubicloud label" -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/size-invalid.json"
check "private, central size a number -> built-in"       "$UBICLOUD" "isn't a Ubicloud label" -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/size-number.json"
check "private, central size ubuntu-latest -> built-in"  "$UBICLOUD" "isn't a Ubicloud label" -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/size-not-ubicloud.json"
check "private, repo size invalid -> built-in, why"      "$UBICLOUD" "CI_FALLBACK_SIZE 'big' isn't a Ubicloud label" -- "${priv[@]}" --runners "$R/offline.json" --settings "$S/size-8.json" --repo-size big
check "public, central 8 and repo 4 -> GitHub-hosted"    "$GITHUB"   "offline"         -- "${pub[@]}"  --runners "$R/offline.json" --settings "$S/size-8.json" --repo-size ubicloud-standard-4
check "private deploy, central 8 -> 8"                   "$U8"       "deploy"          -- --visibility private --fork false --deploy true --runners "$R/idle.json" --settings "$S/size-8.json"
check "private, idle pool, central 8 -> pool"            "$POOL"     "idle"            -- "${priv[@]}" --runners "$R/idle.json" --settings "$S/size-8.json"

echo "# API errors"
check "public, bad credentials -> GitHub-hosted"        "$GITHUB"   "couldn't read the pool" -- "${pub[@]}"  --runners "$R/bad-credentials.json"
check "private, forbidden -> Ubicloud"                  "$UBICLOUD" "couldn't read the pool" -- "${priv[@]}" --runners "$R/forbidden.json"
check "response not JSON -> fallback"                   "$GITHUB"   "couldn't read the pool" -- "${pub[@]}"  --runners "$R/not-json.txt"
check "gh api failed -> fallback, says why"             "$UBICLOUD" "HTTP 502"        -- "${priv[@]}" --runners-error "gh: HTTP 502"
check "no token -> fallback"                            "$GITHUB"   "RUNNER_STATUS_TOKEN" -- "${pub[@]}" --runners-error "RUNNER_STATUS_TOKEN isn't set in this repo"

echo "# Fork pull requests and deploy jobs never use the pool"
check "public fork PR, idle pool -> GitHub-hosted"      "$GITHUB"   "fork"            -- --visibility public  --fork true --deploy false --runners "$R/idle.json"
check "private fork PR, idle pool -> Ubicloud"          "$UBICLOUD" "fork"            -- --visibility private --fork true --deploy false --runners "$R/idle.json"
check "fork PR forced onto the pool -> still fallback"  "$GITHUB"   "fork"            -- --visibility public  --fork true --deploy false --runners "$R/idle.json" --force pool
check "public deploy, idle pool -> GitHub-hosted"       "$GITHUB"   "deploy"          -- --visibility public  --fork false --deploy true --runners "$R/idle.json"
check "private deploy, idle pool -> Ubicloud size"      '"ubicloud-standard-4"' "deploy" -- --visibility private --fork false --deploy true --runners "$R/idle.json" --repo-size ubicloud-standard-4
check "deploy forced onto the pool -> still fallback"   "$UBICLOUD" "deploy"          -- --visibility private --fork false --deploy true --runners "$R/idle.json" --force pool

echo "# Forced choices (for validating a repo)"
check "forced fallback, idle pool -> fallback"          "$UBICLOUD" "forced"          -- "${priv[@]}" --runners "$R/idle.json" --force fallback
check "forced pool, pool offline -> pool (waits)"       "$POOL"     "forced"          -- "${pub[@]}"  --runners "$R/offline.json" --force pool
check "forced pool, no status read -> pool"             "$POOL"     "forced"          -- "${pub[@]}"  --runners-error "RUNNER_STATUS_TOKEN isn't set in this repo" --force pool

echo "# Outputs"
out=$("$decide" "${priv[@]}" --runners "$R/all-busy.json" --repo-size ubicloud-standard-4)
for want in 'choice=pool' 'pool=true' 'fallback="ubicloud-standard-4"' 'overflow=off' 'fallback_size=ubicloud-standard-4 (repo)'; do
  if grep -qxF "$want" <<<"$out"; then pass=$((pass + 1)); echo "ok   output $want"
  else fail=$((fail + 1)); echo "FAIL output $want missing"; sed 's/^/     | /' <<<"$out"; fi
done
out=$("$decide" "${pub[@]}" --runners "$R/offline.json")
for want in 'choice=fallback' 'pool=false' 'fallback="ubuntu-latest"'; do
  if grep -qxF "$want" <<<"$out"; then pass=$((pass + 1)); echo "ok   output $want"
  else fail=$((fail + 1)); echo "FAIL output $want missing"; sed 's/^/     | /' <<<"$out"; fi
done
if "$decide" --visibility public --fork false --deploy false --runners "$R/idle.json" --force sideways >/dev/null 2>&1; then
  fail=$((fail + 1)); echo "FAIL unknown --force value is accepted"
else pass=$((pass + 1)); echo "ok   unknown --force value is refused"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
