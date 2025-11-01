#!/usr/bin/env bash

set -eo pipefail

source /usr/local/lib/colors

backuppath=/mnt/backup

function printx {
  printf "${YELLOW}$1${NOCOLOR}\n"
}

function show_syntax {
  echo "Restore a backup created by fs_backup"
  echo "Syntax: $0 [--include-active] <targetdisk> <backup_device> [backup_name]"
  echo "Where:  [--include-active] is an option to direct restoring to partitions that are active; i.e., online."
  echo "        <targetdisk> is the disk to whicih the restore should be applied."
  echo "        <backup_device> is the device directory containing the backup files."
  echo "        [backup_name] is the name of the specific backup to restore."
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

function select_archive () {
  # Get the archvies and allow selecting
  echo "Listing backup files..."

  # Get the archives
  unset archives
  while IFS= read -r LINE; do
    archives+=("${LINE}")
  done < <( ls "$backuppath/fs" )

  # Get the count of options and increment to include the cancel
  count="${#archives[@]}"
  ((count++))

  COLUMNS=1
  select selection in "${archives[@]}" "Cancel"; do
    if [[ "$REPLY" =~ ^[0-9]+$ && "$REPLY" -ge 1 && "$REPLY" -le $count ]]; then
      case ${selection} in
        "Cancel")
          # If the user decides to cancel...
          break
          ;;
        *)
          archive=$selection
          break
          ;;
      esac
    else
      printx "Invalid selection. Please enter a number between 1 and $count."
    fi
  done

  archivepath="$backuppath/fs/$archive"
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

targetdisk=${1:-}
backupdevice=${2:-}

if [[ $# -gt 2 ]]; then
  archivepath="$backuppath/fs/$3"
fi

echo "include-active=$include_active"
echo "targetdisk=$targetdisk"
echo "backupdevice=$backupdevice"
echo "backuppath=$backuppath"

if [[ -z "$targetdisk" || -z "$backupdevice" ]]; then
  show_syntax
fi

if [[ ! -b "$targetdisk" ]]; then
  printx "Error: $targetdisk not a block device."
  exit 2
fi

if [[ ! -b "$backupdevice" ]]; then
  printx "Error: $backupdevice not a block device."
  exit 2
fi

mount_backup_device

if [ -z $archivepath ]; then
  select_archive
fi
echo "archivepath=$archivepath"
if [[ ! -d "$archivepath" ]]; then
  printx "Error: $archivepath not a directory."
  exit 2
fi

# Check for partition table backup
if [[ ! -f "$archivepath/pt-type" ]]; then
  printx "Error: $archivepath/pt-type not found."
  exit 3
fi

pt_type=$(cat "$archivepath/pt-type")
if [[ "$pt_type" != "gpt" && "$pt_type" != "dos" ]]; then
  printx "Error: Invalid partition table type in $archivepath/pt-type: $pt_type"
  exit 3
fi

# Find available .fsa files
fsa_files=($(ls -1 "$archivepath"/*.fsa 2>/dev/null))
if [[ ${#fsa_files[@]} -eq 0 ]]; then
  printx "Error: No .fsa files found in $archivepath"
  exit 3
fi

# Get the active root partition
root_part=$(findmnt -n -o SOURCE /)

# Filter .fsa files, excluding the active partition unless --include-active is used
partitions=()
menu_items=()
for i in "${!fsa_files[@]}"; do
  fsa_file=${fsa_files[i]}
  partition=$(basename "$fsa_file" .fsa)
  partition_device="/dev/$partition"
  if [[ "$partition_device" == "$root_part" && "$include_active" == "false" ]]; then
    echo "Note: Skipping $partition (active root partition; use --include-active to restore)"
  else
    partitions+=("$partition")
    menu_items+=("$((i+1))" "$partition" "ON")
  fi
done

if [[ ${#partitions[@]} -eq 0 ]]; then
  printx "Error: No valid partitions available for restoration"
  exit 3
fi

# Interactive selection with forced TERM
export TERM=xterm
selection=$(whiptail --title "Select Partitions to Restore" --checklist "Choose one or more:" 15 60 ${#partitions[@]} \
  "${menu_items[@]}" 3>&1 1>&2 2>&3)
if [[ $? -ne 0 ]]; then
  echo "Cancelled: No restoration performed"
  exit
fi

# Convert selected tags (indices) to partition names
IFS=' ' read -ra selected_tags <<< "$selection"
selected=()
for tag in "${selected_tags[@]}"; do
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

# Restore partition table
echo "Restoring partition table to $targetdisk ..."
if [[ "$pt_type" == "gpt" ]]; then
  if [[ ! -f "$archivepath/disk-pt.gpt" ]]; then
    printx "Error: $archivepath/disk-pt.gpt not found."
    exit 1
  fi
  sgdisk --load-backup="$archivepath/disk-pt.gpt" "$targetdisk"
elif [[ "$pt_type" == "dos" ]]; then
  if [[ ! -f "$archivepath/disk-pt.sf" ]]; then
    printx "Error: $archivepath/disk-pt.sf not found."
    exit 1
  fi
  sfdisk "$targetdisk" < "$archivepath/disk-pt.sf"
fi
echo "Partition table restoration complete."

# Inform kernel of partition table changes
partprobe "$targetdisk"

# Restore selected filesystems
for part in "${selected[@]}"; do
  partition_device="/dev/$part"
  fsa_file="$archivepath/$part.fsa"
  if [[ ! -f "$fsa_file" ]]; then
    printx "Error: $fsa_file not found, skipping $partition_device"
    continue
  fi
  if [[ ! -b "$partition_device" ]]; then
    printx "Error: $partition_device not a block device, skipping"
    continue
  fi
  # Check if partition is mounted
  mount_point=$(awk -v part="$partition_device" '$1 == part {print $2}' /proc/mounts)
  if [[ -n "$mount_point" ]]; then
    printx "Error: $partition_device is mounted at $mount_point."
    read -p "Proceed and unmount it first? [y/N] " response
    if [[ "$response" =~ ^[yY]$ ]]; then
      if ! umount "$mount_point"; then
        printx "Error: Failed to unmount $mount_point, skipping $partition_device"
        continue
      fi
    else
      printx "Skipping restoration of $partition_device"
      continue
    fi
  fi
  if [[ "$partition_device" == "$root_part" ]]; then
    printx "Warning: Restoring active root partition $partition_device may cause system instability"
  fi
  echo "Restoring $fsa_file -> $partition_device"
  if ! fsarchiver restfs "$fsa_file" id=0,dest="$partition_device"; then
    printx "Error: Failed to restore $partition_device"
    continue
  fi
done

echo "✅ Restoration complete: $targetdisk"
# lsblk -f "$targetdisk"

unmount_backup_device
