#!/usr/bin/env bash

set -eo pipefail

source /usr/local/lib/colors

supported_fstypes="ext2|ext3|ext4|xfs|btrfs|ntfs|vfat|fat16|fat32|reiserfs"
backuppath=/mnt/backup
dateformat="+%Y%m%d_%H%M%S"
descfile=comment.txt

function printx {
  printf "${YELLOW}$1${NOCOLOR}\n"
}

function show_syntax {
  echo "Create a backup of selected partitions using fsarchiver."
  echo "Syntax: $0 <sourcedisk> <backup_device> [-a|--include-active] [-c|--comment "comment"]"
  echo "Where:  [-a|--include-active] is an option to force inclusion of partitions that are active; i.e., online."
  echo "        [-c|--comment "comment"] is the disk containing the partitions to be included in the backup."
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

function select_partitions {
  local disk=$1 root=$2
  # Get partitions, excluding unsupported filesystems and optionally the active partition

  local partitions=()
  while IFS= read -r partition; do
    local fstype=$(lsblk -fno fstype "$partition" | head -n1)
    if [[ -n "$fstype" && $fstype =~ ^($supported_fstypes)$ ]]; then
      if [[ "$partition" == "$root" && "$include_active" == "false" ]]; then
        # Skip active partitions unless user specifically asks to include them
        echo "Note: Skipping $partition (active root partition; use --include-active to back up)" >&2
      else
        partitions+=("${partition#/dev/}")
      fi
    fi
  done < <(sfdisk --list "$disk" | awk '/^\/dev\// && $1 ~ /'"${disk##*/}"'[0-9]/ {print $1}' | sort)

  if [[ ${#partitions[@]} -eq 0 ]]; then
    printx "No supported filesystems found on $disk" >&2
    exit 2
  fi

  # Prompt the user
  local selected=()
  for i in "${!partitions[@]}"; do
    read -p "Backup partition ${partitions[i]}? (y/N)" yn
    if [[ $yn == "y" || $yn == "Y" ]]; then
      selected+=("${partitions[i]}")
    fi
  done

  # Output the selections
  for i in "${!selected[@]}"; do
    echo "${selected[i]}"
  done
}

# --------------------
# ------- MAIN -------
# --------------------

trap 'unmount_device_at_path "$backuppath"' EXIT

# Retrieve the arguments
arg_short=ac:
arg_long=include-active,comment:
arg_opts=$(getopt --options "$arg_short" --long "$arg_long" --name "$0" -- "$@")
if [ $? != 0 ]; then
    show_syntax
    exit 1
fi

eval set -- "$arg_opts"
while true; do
    case "$1" in
        -a|--include-active)
            include_active=true
            shift
            ;;
        -c|--comment)
            comment="$2"
            shift 2
            ;;
        --) # End of options
            shift
            break
            ;;
        *)
            echo "Internal error parsing arguments: arg=$1"
            exit 1
            ;;
    esac
done

if [ $# -ge 2 ]; then
    sourcedisk="$1"
    backupdevice="$2"
    shift 2
else
    show_syntax
    exit 1
fi

# echo "include-active=$include_active"
# echo "sourcedisk=$sourcedisk"
# echo "backupdevice=$backupdevice"
# echo "comment=$comment"
# exit

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

# Selected the partitions to retore
readarray -t selected < <(select_partitions "$sourcedisk" "$root_part")   

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

# Create description in the snapshot directory
echo "($(sudo du -sh $archivepath | awk '{print $1}')) $comment" > "$archivepath/$descfile"

echo "✅ Backup complete."
# ls -lh "$archivepath"

