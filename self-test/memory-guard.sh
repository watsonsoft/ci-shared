#!/bin/bash
# The memory guard (pc-hardening ticket 23), from inside a pool job: this job's runner has its own memory cap
# below the slice's, systemd-oomd watches the slice, and a job that tries to use more than its runner's cap
# is killed on its own. The next job, pool-after-overrun, checks the other runners stayed online.
set -u
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

cg=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup)
unit=$(echo "$cg" | grep -o 'actions\.runner\.[^/]*\.service' | head -1)
[ -n "$unit" ] && ok "this job runs in its runner's cgroup ($unit)" || bad "this job isn't in a runner service's cgroup: $cg"
dir=/sys/fs/cgroup/user.slice/user-2000.slice/$unit
max=$(cat "$dir/memory.max" 2>/dev/null)
slice_max=$(cat /sys/fs/cgroup/user.slice/user-2000.slice/memory.max 2>/dev/null)
if [ "$max" != max ] && [ -n "$max" ] && [ -n "$slice_max" ] && [ "$max" -lt "$slice_max" ]; then
  ok "the runner's cap ($((max / 2**30)) GiB) is below the slice's ($((slice_max / 2**30)) GiB)"
else
  bad "the runner's memory.max ($max) must be set below the slice's ($slice_max)"
fi
[ "$(cat "$dir/memory.swap.max" 2>/dev/null)" = 0 ] && ok "the runner has no swap" || bad "the runner's memory.swap.max must be 0"

p=$(systemctl show user-2000.slice -p ManagedOOMMemoryPressure --value 2>/dev/null)
[ "$p" = kill ] && ok "systemd-oomd kills on the slice's memory pressure (limit $(( $(systemctl show user-2000.slice -p ManagedOOMMemoryPressureLimit --value) * 100 / 4294967296 ))%)" \
  || bad "user-2000.slice must have ManagedOOMMemoryPressure=kill (got '$p')"
[ "$(systemctl is-active systemd-oomd.service 2>/dev/null)" = active ] && ok "systemd-oomd is running" || bad "systemd-oomd isn't running"

# The overrun: a child that keeps allocating and touching memory past the runner's cap. The kernel must kill it
# (SIGKILL, exit 137) while this script, the job and the runner carry on.
if [ -n "$max" ] && [ "$max" != max ]; then
  before=$(awk '/^oom_kill /{print $2}' "$dir/memory.events")
  want=$(( max / 2**20 + 1024 ))   # MiB: a GiB past the cap
  start=$(date +%s)
  python3 -c '
import sys
chunks = []
for _ in range(int(sys.argv[1]) // 64):
    chunks.append(bytearray(64 * 2**20))   # zero-filled, so every page is touched
print("allocated past the cap without being killed")
' "$want"
  rc=$?
  took=$(( $(date +%s) - start ))
  after=$(awk '/^oom_kill /{print $2}' "$dir/memory.events")
  if [ "$rc" = 137 ] && [ "${after:-0}" -gt "${before:-0}" ]; then
    ok "a child allocating ${want} MiB was OOM-killed inside the runner's cap in ${took}s (exit 137); the job carries on"
  else
    bad "the overrun wasn't killed by the runner's cap: exit $rc, oom_kill $before -> $after, ${took}s"
  fi
  [ "$took" -le 60 ] && ok "the kill came within a minute" || bad "the overrun took ${took}s to be killed: the runner thrashed"
fi
exit $fail
