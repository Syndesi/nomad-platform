#!/bin/sh
# Reboot this node when a newer kernel than the running one is installed. POSIX sh: runs on busybox (alpine) and dash (debian).
#   cluster-reboot --check   print "reboot needed: ..." (exit 10) or "no reboot needed" (exit 0); changes nothing
#   cluster-reboot           the nightly job: reboot if needed (never twice within MIN_HOURS, never right after a boot)
# Managed by ansible (role cluster_reboot).
set -eu

MIN_HOURS=20       # a kernel that does not take (bootloader boots another one) must not turn into a reboot every night
MIN_UPTIME_MIN=30  # a node that has just booted is still starting its services
STATE=/var/lib/cluster-reboot/last

running=$(uname -r)
# newest installed kernel: debian keeps the old ones next to the new one (/boot/vmlinuz-<release>, release starts with a digit); alpine names the file after
# the flavor (/boot/vmlinuz-virt) and replaces the modules of the old kernel (/lib/modules/<release>)
newest=$(ls /boot 2>/dev/null | sed -n 's/^vmlinuz-\([0-9].*\)$/\1/p' | sort -V | tail -1)
[ -n "$newest" ] || newest=$(ls /lib/modules | sort -V | tail -1)

if [ "$newest" = "$running" ] || [ -z "$newest" ]; then
  echo "no reboot needed (kernel $running)"
  exit 0
fi
reason="running kernel $running, installed $newest"

if [ "${1:-}" = "--check" ]; then
  echo "reboot needed: $reason"
  exit 10
fi

now=$(date +%s)
up=$(cut -d. -f1 /proc/uptime)
if [ "$up" -lt $((MIN_UPTIME_MIN * 60)) ]; then
  logger -t cluster-reboot "reboot wanted ($reason) but the node booted $((up / 60)) min ago: not now"
  exit 0
fi
last=$(cat "$STATE" 2>/dev/null || echo 0)
if [ $((now - last)) -lt $((MIN_HOURS * 3600)) ]; then
  logger -t cluster-reboot "reboot wanted ($reason) but the last one was less than ${MIN_HOURS}h ago: not now"
  exit 0
fi

mkdir -p "$(dirname "$STATE")"
echo "$now" > "$STATE"
sync
logger -t cluster-reboot "rebooting: $reason"
exec reboot
