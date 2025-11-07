#!/usr/bin/env bash

set -eo pipefail

source fs_functions.sh

backuppath=/mnt/backup
descfile=comment.txt

show_syntax() {
  echo "Restore a backup created by fs_backup"
  echo "Syntax: $0 [--include-active] <targetdisk> <backup_device> [-b|backup directory]"
  echo "Where:  [--include-active] is an option to direct restoring to partitions that are active; i.e., online."
  echo "        <targetdisk> is the disk to whicih the restore should be applied."
  echo "        <backup_device> is the device containing the backup files."
  echo "        [-b|backup directory] is the name of the specific backup directory to restore."
  exit
}

select_archive() {
  local path=$1
  
  local name archives=()

  # Get the archives
  while IFS= read -r archive; do
    if [ -f "$path/fs/$archive/$descfile" ]; then
      comment=$(cat "$path/fs/$archive/$descfile")
    else
      comment="<no desc>"
    fi
    archives+=("${archive}: $comment")
  done < <( ls -1 "$path/fs" )

  # Get the count of options and increment to include cancel
  local count="${#archives[@]}"
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
          name="${selection%%:*}"
          break
          ;;
      esac
    else
      printx "Invalid selection. Please enter a number between 1 and $count.">&2
    fi
  done

  echo $name
}

restore_partition_table() {
  local disk=$1 path=$2

  # Restore partition table
  if [[ "$pt_type" == "gpt" ]]; then
    if [[ ! -f "$path/disk-pt.gpt" ]]; then
      printx "Error: $path/disk-pt.gpt not found."
      exit 1
    fi
    sgdisk --load-backup="$path/disk-pt.gpt" "$disk"
  elif [[ "$pt_type" == "dos" ]]; then
    if [[ ! -f "$path/disk-pt.sf" ]]; then
      printx "Error: $path/disk-pt.sf not found."
      exit 1
    fi
    sfdisk "$disk" < "$path/disk-pt.sf"
  fi

  # Inform kernel of partition table changes
  partprobe "$disk"
}

restore_filesystem() {
  local part=$1 path=$2 root=$3

  local device="/dev/$part"
  local filepath="$path/$part.fsa"

  if [[ ! -f "$filepath" ]]; then
    printx "Error: $filepath not found, skipping $device"
    continue
  fi
  if [[ ! -b "$device" ]]; then
    printx "Error: $device not a block device, skipping"
    continue
  fi

  # Check if partition is mounted
  local mount_point=$(awk -v part="$device" '$1 == part {print $2}' /proc/mounts)
  if [[ -n "$mount_point" ]]; then
    printx "Error: $device is mounted at $mount_point."
    read -p "Proceed and unmount it first? [y/N] " response
    if [[ "$response" =~ ^[yY]$ ]]; then
      if ! umount "$mount_point"; then
        printx "Error: Failed to unmount $mount_point, skipping $device"
      fi
    else
      printx "Skipping restoration of $device"
    fi
  fi
  if [[ "$device" == "$root" ]]; then
    printx "Warning: Restoring active root partition $device may cause system instability"
  fi
  echo "Restoring $filepath -> $device"
  if ! fsarchiver restfs "$filepath" id=0,dest="$device"; then
    printx "Error: Failed to restore $device"
  fi
}

select_partitions() {
  local path=$1 root=$2 active=$2

  # Find available .fsa files
  local fsa_files=($(ls -1 "$path"/*.fsa 2>/dev/null))
  if [[ ${#fsa_files[@]} -eq 0 ]]; then
    printx "Error: No .fsa files found in $path" >&2
    exit 3
  fi

  # Filter .fsa files, excluding the active partition unless --include-active is used
  local partitions=()
  for i in "${!fsa_files[@]}"; do
    local filename=${fsa_files[i]}
    local partname=$(basename "$filename" .fsa)
    local device="/dev/$partname"
    if [[ "$device" == "$root" && "$active" == "false" ]]; then
      echo "Note: Skipping $partname (active root partition; use --include-active to restore)" >&2
    else
      partitions+=("$partname")
    fi
  done
  if [[ ${#partitions[@]} -eq 0 ]]; then
    printx "Error: No valid partitions available for restore." >&2
    exit 3
  fi

  local selected=()
  for i in "${!partitions[@]}"; do
      read -p "Restore partition ${partitions[i]}? (y/N)" yn
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

# Get the arguments
arg_short=ad:
arg_long=include-active,directory:
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
    -d|--directory)
      archivename="$2"
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
  targetdisk="$1"
  backupdevice="$2"
  shift 2
else
  show_syntax >&2
  exit 1
fi

# echo "backuppath=$backuppath"
# echo "include-active=$include_active"
# echo "targetdisk=$targetdisk"
# echo "backupdevice=$backupdevice"
# echo "archivename=$archivename"
# exit

if [[ ! -b "$targetdisk" ]]; then
  printx "Error: The specified target disk '$targetdisk' is not a block device."
  exit 2
fi

if [[ ! -b "$backupdevice" ]]; then
  printx "Error: The specified backup device '$backupdevice' is not a block device."
  exit 2
fi

mount_device_at_path "$backupdevice" "$backuppath"

if [ -z $archivename ]; then
  echo "Select an archive..."
  archivename=$(select_archive "$backuppath")
  if [ -z $archivename ]; then
    echo "Operation cancelled" >&2
    exit
  else
    archivepath="$backuppath/fs/$archivename"
  fi
else
  archivepath="$backuppath/fs/$archivename"
  if [[ ! -d "$archivepath" ]]; then
    printx "Error: '$archivename' not a found on '$backupdevice'."
    exit 2
  fi
fi

echo "Restoring '$archivename' to '$targetdisk'..."

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

# Get the active root partition
root_part=$(findmnt -n -o SOURCE /)

# Selected the partitions to retore
readarray -t selected < <(select_partitions "$archivepath" "$root_part" "$include_active")   

# Output selected options
# echo "Show selections"
# for i in "${!selected[@]}"; do
#     echo "${selected[i]}"
# done
# read

if [[ "${#selected[@]}" > 0 ]]; then
  echo "Restoring partition table to $targetdisk ..."
  restore_partition_table "$targetdisk" "$archivepath"

  for partition in "${selected[@]}"; do
    restore_filesystem "$partition" "$archivepath" "$root_part"
  done

  echo "✅ Restoration complete."
else
  printx "No partitions were selected for restore."
fi
