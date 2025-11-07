#!/usr/bin/env bash

# Restore an fs_backup

source /usr/local/lib/fs_shared

show_syntax() {
  echo "Restore a backup created by fs_backup"
  echo "Syntax: $0 <backup_device> <target_disk> [-a|--include-active] [-b|--backup]"
  echo "Where:  <backup_device> can be a backupdevice designator (e.g., /dev/sdb6), a UUID, filesystem LABEL, or partition UUID"
  echo "        <target_disk> is the disk to which the restore should be applied."
  echo "        [-a|--include-active] is an option to direct restoring to partitions that are active; i.e., online."
  echo "        [-b|backup directory] is the name of the specific backup directory to restore."
  exit
}

restore_partition_table() {
  local disk=$1 path=$2

  # Restore partition table
  if [[ "$pt_type" == "gpt" ]]; then
    if [[ ! -f "$path/disk-pt.gpt" ]]; then
      printx "Error: $path/disk-pt.gpt not found." >&2
      exit 1
    fi
    sgdisk --load-backup="$path/disk-pt.gpt" "$disk" &>> "$g_outputfile"
  elif [[ "$pt_type" == "dos" ]]; then
    if [[ ! -f "$path/disk-pt.sf" ]]; then
      printx "Error: $path/disk-pt.sf not found." >&2
      exit 1
    fi
    sfdisk "$disk" < "$path/disk-pt.sf" &>> "$g_outputfile"
  fi

  # Inform kernel of partition table changes
  partprobe "$disk"
}

restore_filesystem() {
  local part=$1 path=$2 root=$3

  local device="/dev/$part"
  local filepath="$path/$part.fsa"

  if [[ ! -f "$filepath" ]]; then
    printx "Error: $filepath not found, skipping $device" >&2
    continue
  fi
  if [[ ! -b "$device" ]]; then
    printx "Error: $device not a block device, skipping" >&2
    continue
  fi

  # Check if partition is mounted
  local mount=$(mountpoint -q $path)
  if [[ -n "$mount" ]]; then
    printx "Error: $device is mounted at $mount." >&2
    read -p "Proceed and unmount it first? [y/N] " response
    if [[ "$response" =~ ^[yY]$ ]]; then
      if ! umount "$mount"; then
        printx "Error: Failed to unmount $mount, skipping $device" >&2
      fi
    else
      printx "Skipping restoration of $device" >&2
    fi
  fi
  if [[ "$device" == "$root" ]]; then
    printx "Warning: Restoring active root partition $device may cause system instability" >&2
  fi
  echo "Restoring $filepath -> $device"
  fsarchiver restfs "$filepath" id=0,dest="$device" &>> "$g_outputfile"
  if [ $? -ne 0 ]; then
    printx "Error: Failed to restore $device" >&2
  fi
}

select_restore_partitions() {
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

trap 'unmount_device_at_path "$g_backuppath"' EXIT

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
    -b|--backup)
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
  arg="$1"
  shift 1
  device="${arg#/dev/}" # in case it is a device designator
  backupdevice="/dev/$(lsblk -ln -o NAME,UUID,PARTUUID,LABEL | grep "$device" | tr -s ' ' | cut -d ' ' -f1)"
  if [ -z $backupdevice ]; then
    printx "No valid device was found for '$device'."
    exit
  fi
  targetdisk="$2"
  shift 1
  if [[ ! -b "$targetdisk" ]]; then
  printx "Error: The specified target '$targetdisk' is not a block device."
  exit
else
  show_syntax
fi

# echo "targetdisk=$targetdisk"
# echo "backupdevice=$backupdevice"
# echo "archivename=$archivename"
# echo "include-active=$include_active"

if [ -z $backupdevice ] || [ -z $targetdisk ]; then
  show_syntax
fi

if [[ "$EUID" != 0 ]]; then
  printx "This must be run as sudo.\n"
  exit 1
fi

# Initialize the log file
echo &> "$g_outputfile"

mount_device_at_path "$backupdevice" "$g_backuppath"

if [ -z $archivename ]; then
  echo "Select an archive..."
  archivename=$(select_archive "$g_backuppath")
  if [ -z $archivename ]; then
    echo "Operation cancelled" >&2
    exit
  else
    archivepath="$g_backuppath/$g_backupdir/$archivename"
  fi
else
  archivepath="$g_backuppath/$g_backupdir/$archivename"
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
readarray -t selected < <(select_restore_partitions "$archivepath" "$root_part" "$include_active")   

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
  echo "Details of the operation can be viewed in the file /tmp/$g_outputfile"
else
  printx "No partitions were selected for restore."
fi
