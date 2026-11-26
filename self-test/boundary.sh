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

# --- what CI needs ---
check "KSP is readable"                         test -r /mnt/ksp/KSP_x64_Data/Managed/Assembly-CSharp.dll
check "KSP is read-only"                        not touch /mnt/ksp/.selftest-write
check "internet reachable"                      curl -fsS --max-time 10 https://api.github.com/zen

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
