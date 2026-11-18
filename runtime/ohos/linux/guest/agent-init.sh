#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /tmp
chmod 1777 /tmp
ip link set lo up
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2
hostname dsh-guest
epoch=
for arg in $(cat /proc/cmdline); do
 case "$arg" in
 dsh.epoch=*) epoch=${arg#dsh.epoch=} ;;
 dsh.time=*) stamp=${arg#dsh.time=}; case "$stamp" in ''|*[!0-9]*) ;; *) date -u -s "@$stamp" >/dev/null ;; esac ;;
 esac
done
case "$epoch" in ''|*[!0-9a-f]*) echo __DSH_INSTALL_FAILED__; exit 1 ;; esac
[ ${#epoch} -eq 64 ] || exit 1
exec /usr/bin/python3 -u /usr/local/lib/dsh/guest-agent.py --epoch "$epoch"
