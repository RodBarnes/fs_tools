#!/usr/bin/env bash

set -eo pipefail

source /usr/local/lib/colors

supported_fstypes="ext2|ext3|ext4|xfs|btrfs|ntfs|vfat|fat16|fat32|reiserfs"
backuppath=/mnt/backup
dateformat="+%Y%m%d_%H%M%S"

function printx {
  printf "${YELLOW}$1${NOCOLOR}\n"
}

function show_syntax {
  echo "Create a backup of selected partitions using fsarchiver."
  echo "Syntax: $0 [--include-active] <sourcedisk> <backup_device>"
  echo "Where:  [--include-active] is an option to force inclusion of partitions that are active; i.e., online."
  echo "        <sourcedisk> is the disk containing the partitions to be included in the backup."
  echo "        <backup_device> is the device where the backup should be stored."
  exit
}

function mount_backup_device {
  # Ensure mount point exists
  if [ ! -d $backuppath ]; then
    sudo mkdir -p $backuppath #&> /dev/null
    if [ $? -ne 0 ]; then
      printx "Unable to locate or create '$backuppath'."
      exit 2
    fi
  fi

  # Attempt to mount the device
  sudo mount $backupdevice $backuppath #&> /dev/null
  if [ $? -ne 0 ]; then
    printx "Unable to mount the backup backupdevice '$backupdevice'."
    exit 2
  fi

  # Ensure the directory structure exists
  if [ ! -d "$backuppath/fs" ]; then
    sudo mkdir "$backuppath/fs" $&> /dev/null
    if [ $? -ne 0 ]; then
      printx "Unable to locate or create '$backuppath/fs'."
      exit 2
    fi
  fi
}

function unmount_backup_device {
  sudo umount $backuppath
}

function backup_partition_table() {
  local disk=$1 imgdir=$2
  if fdisk -l "$disk" 2>/dev/null | grep -q '^Disklabel type: gpt'; then
    sgdisk --backup="$imgdir/disk-pt.gpt" "$disk"
    echo "gpt" > "$imgdir/pt-type"
  else
    sfdisk --dump "$disk" > "$imgdir/disk-pt.sf"
    echo "dos" > "$imgdir/pt-type"
  fi
  echo "Saved partition table to $imgdir/"
}

function backup_filesystem {
    # Detect if mounted RW
  partition_device="/dev/$partition"
  mounted_rw=false
  mount_point=$(awk -v part="$partition_device" '$1 == part {print $2}' /proc/mounts)
  if [[ -n "$mount_point" ]]; then
    if awk -v part="$partition_device" '$1 == part {print $4}' /proc/mounts | grep -q '^rw'; then
      mounted_rw=true
      printx "Warning: $partition_device is mounted RW at $mount_point (live backup may have minor inconsistencies)"
      printx "Consider remounting read-only with: mount -o remount,ro $mount_point"
    else
      echo "Note: $partition_device is mounted read-only at $mount_point"
    fi
  fi

  suffix=${partition##$sourcedisk}
  fsa_file="$imgdir/$suffix.fsa"
  
  # echo "sourcedisk##*/=${sourcedisk##*/}"
  # echo "partition_device=$partition_device"
  # echo "fsa_file=$fsa_file"
  # echo "sourcedisk=$sourcedisk"
  # echo "imgdir=$imgdir"
  # echo "partition=$partition"
  # echo "suffix=$suffix"
  # echo "sourcedisk##*/=${sourcedisk##*/}"
  # read

  options="-v -j$(nproc) -Z3"
  if $mounted_rw; then
    options="$options -A"
  fi

  logfile="/tmp/fs_backup_$suffix.out"

  echo "Backing up $partition_device -> $fsa_file"
  if ! fsarchiver savefs $options "$fsa_file" "$partition_device" &> $logfile; then
    printx "Error: Failed to back up $partition_device"
  else
    echo "Output of fsarchvier written to '$logfile'"
  fi
}

# --------------------
# ------- MAIN -------
# --------------------

# Check for --include-active flag
include_active=false
if [[ $# -gt 0 && "$1" == "--include-active" ]]; then
  include_active=true
  shift
fi

# Get other arguments
sourcedisk=${1:-}
backupdevice=${2:-}

# echo "include-active=$include_active"
# echo "sourcedisk=$sourcedisk"
# echo "backupdevice=$backupdevice"

if [[ -z "$sourcedisk" || -z "$backupdevice" ]]; then
  show_syntax
fi

if [[ ! -b "$backupdevice" ]]; then
  printx "Error: $backupdevice not a block device."
  exit 2
fi

if [[ ! -b "$sourcedisk" ]]; then
  printx "Error: $sourcedisk not a block device."
  exit 2
fi

mount_backup_device

# Get the active root partition
root_part=$(findmnt -n -o SOURCE /)

# Get partitions, excluding unsupported filesystems and optionally the active partition
partitions=()
while IFS= read -r partition; do
  fstype=$(lsblk -fno fstype "$partition" | head -n1)
  if [[ -n "$fstype" && $fstype =~ ^($supported_fstypes)$ ]]; then
    if [[ "$partition" == "$root_part" && "$include_active" == "false" ]]; then
      # Skip active partitions unless user specifically asks to include them
      echo "Note: Skipping $partition (active root partition; use --include-active to back up)"
    else
      partitions+=("${partition#/dev/}")
    fi
  fi
done < <(sfdisk --list "$sourcedisk" | awk '/^\/dev\// && $1 ~ /'"${sourcedisk##*/}"'[0-9]/ {print $1}' | sort)

if [[ ${#partitions[@]} -eq 0 ]]; then
  printx "No supported filesystems found on $sourcedisk"
  exit 2
fi

# Prompt the user
selected=()
for i in "${!partitions[@]}"; do
    read -p "Backup partition ${partitions[i]}? (y/N)" yn
    if [[ $yn == "y" || $yn == "Y" ]]; then
      selected+=("${partitions[i]}")
    fi
done

# Output selected options
# echo "Show selections"
# for i in "${!selected[@]}"; do
#     echo "${selected[i]}"
# done
# read

if [[ ${#selected[@]} -eq 0 ]]; then
  printx "Error: No valid partitions selected"
  exit
fi

# Create backup directory and save partition table
imgdir="$backuppath/fs/$(date $dateformat)_$(hostname -s)"
mkdir -p "$imgdir"
backup_partition_table "$sourcedisk" "$imgdir"

echo "Backing up selected partitions to $imgdir/ ..."

for partition in "${selected[@]}"; do
  backup_filesystem
done

echo "✅ Backup complete: $imgdir"
# ls -lh "$imgdir"

unmount_backup_device
