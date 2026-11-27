#!/usr/bin/env bash
# The runner pool's self-test (pc-hardening ADR 0001, amended): checks, from inside a real job on the pool,
# that the runner environment keeps jobs away from the owner's files and Windows and still gives them what
# CI needs. Prints PASS/FAIL per check and exits non-zero if any check fails.
# SERVICE_PORT: the host port of the workflow's nginx service container.
set -u
fails=0
check() { # description, then a command that succeeds when the protection holds
  local what=$1; shift
  if ( "$@" ) >/dev/null 2>&1; then echo "PASS  $what"; else echo "FAIL  $what"; fails=$((fails + 1)); fi
}
not() { ! "$@"; }

echo "runner: ${RUNNER_NAME:-?}  user: $(id -un) ($(id -u))  host: $(hostname)"
echo

# --- cut off from the owner's files and Windows ---
check "job is not root"                         test "$(id -u)" != 0
check "no sudo"                                 not sudo -n true
check "owner's home folder isn't here"          not test -e /home/awats
check "C: isn't mounted"                        not test -e /mnt/c/Windows
check "can't mount C: (drvfs)"                  not mount -t drvfs 'C:\' "$(mktemp -d)"
check "can't mount C: in a user namespace"      not unshare -rm mount -t drvfs 'C:\' /mnt
blockdevs=(/dev/sd? /dev/vd?)
for d in "${blockdevs[@]}"; do
  [ -b "$d" ] || continue
  check "can't read disk $d"                    not head -c 1 "$d"
  check "can't mount disk $d in a user namespace" not unshare -rm mount -o ro "$d" /mnt
done
# The binfmt handler is shared by every distro, so it's registered here too; what stops a .exe launching on
# Windows is this distro's own interop setting, which WSL enforces (proven with a real cmd.exe in ticket 02).
check "Windows interop is off for this distro"  sh -c "awk '/^\\[interop\\]/{s=1;next} /^\\[/{s=0} s' /etc/wsl.conf | grep -qx 'enabled=false'"
check "no WSLg desktop socket"                  not test -e /tmp/.X11-unix/X0
check "no shared /mnt/wsl"                      not test -e /mnt/wsl/resolv.conf

# --- Docker is rootless: a privileged container still can't reach the disks ---
check "Docker runs"                             docker run --rm alpine:3.20 true
check "Docker is rootless"                      sh -c 'docker info --format "{{.SecurityOptions}}" | grep -q rootless'
for d in "${blockdevs[@]}"; do
  [ -b "$d" ] || continue
  # Passes only if the container ran and saw the device, then couldn't read it.
  check "privileged container can't read $d"   docker run --rm --privileged -v /dev:/hostdev alpine:3.20 \
    sh -c "test -b /hostdev/${d#/dev/} && ! head -c 1 /hostdev/${d#/dev/} >/dev/null 2>&1"
done
check "service container reachable on its host port" curl -fsS --max-time 10 "http://127.0.0.1:${SERVICE_PORT:?}/"

# --- network (ticket 03): jobs live in rootless Docker's network namespace; uid 2000 can't reach private ranges ---
unreachable() { ! timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
[ -r /etc/ci-hostinfo ] && . /etc/ci-hostinfo
# Only the namespace's own interfaces: the host's (eth*, wlan*, loopback0 under mirrored networking) mean the job
# is on the host network.
check "has its own network namespace (no host interfaces)" sh -c '! ip -br link | awk "{sub(/@.*/, \"\", \$1); print \$1}" | grep -vqE "^(lo|tap0|docker0|br-[0-9a-f]+|veth[0-9a-f]+)$"'
check "lineup-hq (127.0.0.1:8000) unreachable"       unreachable 127.0.0.1 8000
check "cockpit (127.0.0.1:48765) unreachable"        unreachable 127.0.0.1 48765
check "test-count reader (127.0.0.1:48767) unreachable" unreachable 127.0.0.1 48767
check "host via slirp (10.0.2.2:22) unreachable"     unreachable 10.0.2.2 22
check "PC's LAN address (${LAN_IP:-unknown}:22) unreachable" sh -c "test -n '${LAN_IP:-}' && ! timeout 5 bash -c 'exec 3<>/dev/tcp/${LAN_IP:-0}/22' 2>/dev/null"
check "Meshnet (100.112.203.32:22) unreachable"      unreachable 100.112.203.32 22
check "home router (192.168.1.1:80) unreachable"     unreachable 192.168.1.1 80
check "a container can't reach the LAN either"       sh -c "! docker run --rm alpine:3.20 timeout 5 nc -z ${LAN_IP:-192.168.1.1} 22"

# --- memory (ticket 03): everything CI runs is under one capped slice ---
check "CI memory is capped (user-2000.slice)"        sh -c 'm=$(cat /sys/fs/cgroup/user.slice/user-2000.slice/memory.max) && [ "$m" != max ] && [ "$m" -le $((14 * 1024 * 1024 * 1024)) ] && grep -q "user-2000.slice" /proc/self/cgroup'

# --- priority (ticket 16): CI is the third tier, well below the owner's main distro (weight 100) ---
check "CI CPU weight is low (user-2000.slice)"       sh -c 'w=$(cat /sys/fs/cgroup/user.slice/user-2000.slice/cpu.weight) && [ "$w" -le 20 ]'

# --- after-job cleanup (ticket 04) ---
check "after-job cleanup hook is set"                sh -c 'test -x "${ACTIONS_RUNNER_HOOK_JOB_COMPLETED:-/nonexistent}"'
check "nightly Docker prune is scheduled"            test -e /etc/systemd/system/timers.target.wants/ci-docker-prune.timer

# --- what CI needs ---
check "KSP is readable"                         test -r /mnt/ksp/KSP_x64_Data/Managed/Assembly-CSharp.dll
check "KSP is read-only"                        not touch /mnt/ksp/.selftest-write
check "internet reachable"                      curl -fsS --max-time 10 https://api.github.com/zen

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
