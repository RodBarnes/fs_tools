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
while IFS= read -r part; do
  fstype=$(lsblk -fno fstype "$part" | head -n1)
  if [[ -n "$fstype" && $fstype =~ ^($supported_fstypes)$ ]]; then
    if [[ "$part" == "$root_part" && "$include_active" == "false" ]]; then
      # Skip active partitions unless user specifically asks to include them
      echo "Note: Skipping $part (active root partition; use --include-active to back up)"
    else
      partitions+=("$part")
    fi
  fi
done < <(sfdisk --list "$sourcedisk" | awk '/^\/dev\// && $1 ~ /'"${sourcedisk##*/}"'[0-9]/ {print $1}' | sort)

if [[ ${#partitions[@]} -eq 0 ]]; then
  printx "No supported filesystems found on $sourcedisk"
  exit 2
fi

# Prepare whiptail checklist items: "index" "partition" "state"
menu_items=()
for i in "${!partitions[@]}"; do
  menu_items+=("$((i+1))" "${partitions[i]}" "ON")
done

# Interactive selection with forced TERM
export TERM=xterm
selection=$(whiptail --title "Select Partitions to Backup" --checklist "Choose one or more:" 15 60 ${#partitions[@]} \
  "${menu_items[@]}" 3>&1 1>&2 2>&3)
if [[ $? -ne 0 ]]; then
  # User cancelled
  exit
fi

# Convert selected tags (indices) to partition names
IFS=' ' read -ra selected_tags <<< "$selection"
selected=()
for tag in "${selected_tags[@]}"; do
  # Remove quotes from tag
  tag_clean=${tag//\"/}
  if [[ $tag_clean =~ ^[0-9]+$ ]]; then
    index=$((tag_clean-1))
    if [[ $index -ge 0 && $index -lt ${#partitions[@]} ]]; then
      selected+=("${partitions[index]}")
    else
      printx "Warning: Invalid tag '$tag_clean' ignored"
    fi
  else
    printx "Warning: Non-numeric tag '$tag_clean' ignored"
  fi
done

if [[ ${#selected[@]} -eq 0 ]]; then
  printx "Error: No valid partitions selected"
  exit
fi

# Create backup directory and save partition table
imgdir="$backuppath/fs/$(date $dateformat)_$(hostname -s)"
mkdir -p "$imgdir"
backup_partition_table "$sourcedisk" "$imgdir"

echo "Backing up selected partitions to $imgdir/ ..."

for part in "${selected[@]}"; do
  # Detect if mounted RW
  mounted_rw=false
  mount_point=$(awk -v part="$part" '$1 == part {print $2}' /proc/mounts)
  if [[ -n "$mount_point" ]]; then
    if awk -v part="$part" '$1 == part {print $4}' /proc/mounts | grep -q '^rw'; then
      mounted_rw=true
      printx "Warning: $part is mounted RW at $mount_point (live backup may have minor inconsistencies)"
      printx "Consider remounting read-only with: mount -o remount,ro $mount_point"
    else
      echo "Note: $part is mounted read-only at $mount_point"
    fi
  fi

  suffix=${part##$sourcedisk}
  fsa_file="$imgdir/${sourcedisk##*/}$suffix.fsa"

  # echo "sourcedisk=$sourcedisk"
  # echo "imgdir=$imgdir"
  # echo "part=$part"
  # echo "suffix=$suffix"
  # echo "sourcedisk##*/=${sourcedisk##*/}"
  # echo "part="

  options="-v -j$(nproc) -Z3"
  if $mounted_rw; then
    options="$options -A"
  fi

  logfile="/tmp/fs_backup_${sourcedisk##*/}$suffix.out"

  echo "Backing up $part -> $fsa_file"
  if ! fsarchiver savefs $options "$fsa_file" "$part" &> $logfile; then
    printx "Error: Failed to back up $part"
  else
    echo "Output of fsarchvier written to '$logfile'"
  fi
done

echo "✅ Backup complete: $imgdir"
# ls -lh "$imgdir"

unmount_backup_device
