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

function mount_device_at_path {
  local device=$1 mount=$2
  # Ensure mount point exists
  if [ ! -d $mount ]; then
    sudo mkdir -p $mount
    if [ $? -ne 0 ]; then
      printx "Unable to locate or create '$mount'." >&2
      exit 2
    fi
  fi

  # Attempt to mount the device
  sudo mount $device $mount
  if [ $? -ne 0 ]; then
    printx "Unable to mount the backup backupdevice '$device'." >&2
    exit 2
  fi

  # Ensure the directory structure exists
  if [ ! -d "$mount/fs" ]; then
    sudo mkdir "$mount/fs"
    if [ $? -ne 0 ]; then
      printx "Unable to locate or create '$mount/fs'." >&2
      exit 2
    fi
  fi
}

function unmount_device_at_path {
  local mount=$1
  # Unmount if mounted
  if [ -d "$mount/fs" ]; then
    sudo umount $mount
  fi
}

function backup_partition_table() {
  local disk=$1 path=$2
  # Get the partition info
  if fdisk -l "$disk" 2>/dev/null | grep -q '^Disklabel type: gpt'; then
    sgdisk --backup="$path/disk-pt.gpt" "$disk"
    echo "gpt" > "$path/pt-type"
  else
    sfdisk --dump "$disk" > "$path/disk-pt.sf"
    echo "dos" > "$path/pt-type"
  fi
}

function backup_filesystem {
  local partfs=$1 path=$2
  # Detect if mounted RW
  local partition_device="/dev/$partfs"
  local mounted_rw=false
  local mount_point=$(awk -v part="$partition_device" '$1 == part {print $2}' /proc/mounts)
  if [[ -n "$mount_point" ]]; then
    if awk -v part="$partition_device" '$1 == part {print $4}' /proc/mounts | grep -q '^rw'; then
      mounted_rw=true
      printx "Warning: $partition_device is mounted RW at $mount_point (live backup may have minor inconsistencies)" >&2
      printx "Consider remounting read-only with: mount -o remount,ro $mount_point" >&2
    else
      echo "Note: $partition_device is mounted read-only at $mount_point" >&2
    fi
  fi

  local suffix=${partfs##$sourcedisk}
  local fsa_file="$path/$suffix.fsa"
  
  # echo "sourcedisk##*/=${sourcedisk##*/}"
  # echo "partition_device=$partition_device"
  # echo "fsa_file=$fsa_file"
  # echo "sourcedisk=$sourcedisk"
  # echo "path=$path"
  # echo "partition=$partition"
  # echo "suffix=$suffix"
  # echo "sourcedisk##*/=${sourcedisk##*/}"
  # read

  local options="-v -j$(nproc) -Z3"
  if $mounted_rw; then
    options="$options -A"
  fi

  local logfile="/tmp/fs_backup_$suffix.out"

  printf "Backing up $partition_device to archive..." >&2
  if ! fsarchiver savefs $options "$fsa_file" "$partition_device" &> $logfile; then
    printx "\nError: Failed to back up $partition_device" >&2
  else
    printf " log written to '$logfile'\n" >&2
  fi
}

# --------------------
# ------- MAIN -------
# --------------------

trap 'unmount_device_at_path "$backuppath"' EXIT

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

mount_device_at_path "$backupdevice" "$backuppath"

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
archivepath="$backuppath/fs/$(date $dateformat)_$(hostname -s)"
mkdir -p "$archivepath"

echo "Saving partition table to $archivepath/..."
backup_partition_table "$sourcedisk" "$archivepath"

echo "Backing up selected partitions to $archivepath/ ..."
for partition in "${selected[@]}"; do
  backup_filesystem "$partition" "$archivepath"
done

echo "✅ Backup complete: $archivepath"
# ls -lh "$archivepath"

