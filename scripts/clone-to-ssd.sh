#!/bin/bash
# Copy the running system (booted from an SD card) onto an SSD, so the Pi can boot from the SSD.
#
# Usage, as the normal user, on the Pi booted from the SD card with the SSD attached:
#
#   TARGET=/dev/sda CONFIRM=/dev/sda scripts/clone-to-ssd.sh
#
# Everything on TARGET is overwritten. The script refuses to run unless TARGET is a whole disk,
# is not the disk the system runs from and has no mounted partition, and CONFIRM repeats it.
#
# What it does: copies the boot disk block by block, gives the copy a new disk identifier and
# adjusts the PARTUUIDs in cmdline.txt and fstab (two disks with the same identifier would boot
# the wrong root), grows the root partition to fill the SSD, and optionally restores SSH host keys
# so that clients keep trusting the host.
#
# Environment:
#   TARGET        the SSD, e.g. /dev/sda (required)
#   CONFIRM       must equal TARGET (required)
#   HOSTKEYS_DIR  directory with the old ssh_host_* files to install on the copy (optional)
#
# Afterwards: shut down, remove the SD card, power on. With the SD card in, the Pi boots from it.
set -euo pipefail

TARGET=${TARGET:-}
CONFIRM=${CONFIRM:-}
HOSTKEYS_DIR=${HOSTKEYS_DIR:-}

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the normal user, not as root; it uses sudo where needed." >&2
    exit 1
fi
if [ -z "$TARGET" ] || [ "$CONFIRM" != "$TARGET" ]; then
    echo "Set TARGET (e.g. /dev/sda) and CONFIRM to the same value." >&2
    exit 1
fi
if [ "$(lsblk -dno TYPE "$TARGET" 2> /dev/null)" != disk ]; then
    echo "$TARGET is not a whole disk." >&2
    exit 1
fi

root_src=$(findmnt -no SOURCE /)
source_disk=/dev/$(lsblk -no PKNAME "$root_src" | head -n 1)
if [ "$source_disk" = "$TARGET" ]; then
    echo "$TARGET is the disk the system runs from." >&2
    exit 1
fi
if lsblk -nlo MOUNTPOINTS "$TARGET" | grep -q .; then
    echo "A partition of $TARGET is mounted; unmount it first." >&2
    exit 1
fi

src_size=$(lsblk -bdno SIZE "$source_disk")
dst_size=$(lsblk -bdno SIZE "$TARGET")
if [ "$dst_size" -lt "$src_size" ]; then
    echo "$TARGET ($dst_size bytes) is smaller than $source_disk ($src_size bytes)." >&2
    exit 1
fi

echo "Source: $source_disk ($(lsblk -dno SIZE "$source_disk"))"
echo "Target: $TARGET ($(lsblk -dno MODEL,SIZE "$TARGET")), will be overwritten"

echo "==> Copy"
sync
sudo dd if="$source_disk" of="$TARGET" bs=4M conv=fsync status=progress

echo "==> New disk identifier"
old_id=$(sudo sfdisk --disk-id "$source_disk")
new_id=0x$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
sudo sfdisk --disk-id "$TARGET" "$new_id"
sudo partprobe "$TARGET"
sudo udevadm settle
old_id=${old_id#0x}
new_id=${new_id#0x}

echo "==> Grow the root partition"
part_prefix=$TARGET
case "$TARGET" in *[0-9]) part_prefix=${TARGET}p ;; esac
sudo parted -s "$TARGET" resizepart 2 100%
sudo partprobe "$TARGET"
sudo udevadm settle
sudo e2fsck -fy "${part_prefix}2"
sudo resize2fs "${part_prefix}2"

echo "==> PARTUUIDs and host keys"
mnt=$(mktemp -d)
trap 'sudo umount "$mnt/boot/firmware" 2> /dev/null || true; sudo umount "$mnt" 2> /dev/null || true; rmdir "$mnt" 2> /dev/null || true' EXIT
sudo mount "${part_prefix}2" "$mnt"
sudo mount "${part_prefix}1" "$mnt/boot/firmware"
sudo sed -i "s/$old_id/$new_id/g" "$mnt/boot/firmware/cmdline.txt" "$mnt/etc/fstab"
grep -q "$new_id" "$mnt/boot/firmware/cmdline.txt" || {
    echo "cmdline.txt does not contain the new PARTUUID." >&2
    exit 1
}
if [ -n "$HOSTKEYS_DIR" ]; then
    # sudo sh -c: the directory may be readable by root only
    sudo sh -c "cp -p '$HOSTKEYS_DIR'/ssh_host_* '$mnt/etc/ssh/'"
fi
sync

echo "==> Done. Shut down, remove the SD card, power on."
