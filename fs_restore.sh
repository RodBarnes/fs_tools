#!/usr/bin/env bash

# Restore an fs_backup

source /usr/local/lib/fs_shared

show_syntax() {
  echo "Restore a backup created by fs_backup"
  echo "Syntax: $0 <backup_device> <target_disk> [-b|--backup]"
  echo "Where:  <backup_device> can be a backupdevice designator (e.g., /dev/sdb6), a UUID, filesystem LABEL, or partition UUID"
  echo "        <target_disk> is the disk to which the restore should be applied."
  echo "        [-b|backup directory] is the name of the specific backup directory to restore."
  exit
}

restore_partition_table() {
  local disk=$1 path=$2

  # Restore partition table
  if [[ "$pt_type" == "gpt" ]]; then
    if [[ ! -f "$path/disk-pt.gpt" ]]; then
      showx "Error: $path/disk-pt.gpt not found."
      exit 1
    fi
    sgdisk --load-backup="$path/disk-pt.gpt" "$disk" &>> "$g_logfile"
  elif [[ "$pt_type" == "dos" ]]; then
    if [[ ! -f "$path/disk-pt.sf" ]]; then
      showx "Error: $path/disk-pt.sf not found."
      exit 1
    fi
    sfdisk "$disk" < "$path/disk-pt.sf" &>> "$g_logfile"
  fi

  # Inform kernel of partition table changes
  partprobe "$disk"
}

restore_filesystem() {
  local part=$1 path=$2 root=$3

  local device="/dev/$part"
  local filepath="$path/$part.fsa"

  if [[ ! -f "$filepath" ]]; then
    showx "Error: $filepath not found, skipping $device"
    continue
  fi
  if [[ ! -b "$device" ]]; then
    showx "Error: $device not a block device, skipping"
    continue
  fi

  # Check if partition is mounted
  local mount=$(mountpoint -q $path)
  if [[ -n "$mount" ]]; then
    showx "Error: $device is mounted at $mount."
    readx -p "Proceed and unmount it first? [y/N] " yn
    if [[ "$yn" =~ ^[yY]$ ]]; then
      if ! umount "$mount"; then
        showx "Error: Failed to unmount $mount, skipping $device"
      fi
    else
      showx "Skipping restoration of $device"
    fi
  fi
  if [[ "$device" == "$root" ]]; then
    showx "Warning: Restoring active root partition $device may cause system instability"
  fi
  show "Restoring $filepath -> $device"
  fsarchiver restfs "$filepath" id=0,dest="$device" &>> "$g_logfile"
  if [ $? -ne 0 ]; then
    showx "Error: Failed to restore $device"
  fi
}

select_restore_partitions() {
  local path=$1 root=$2 active=$2

  # Find available .fsa files
  local fsa_files=($(ls -1 "$path"/*.fsa 2>/dev/null))
  if [[ ${#fsa_files[@]} -eq 0 ]]; then
    showx "Error: No .fsa files found in $path"
    exit 3
  fi

  # Filter .fsa files, excluding the active partition
  local partitions=()
  for i in "${!fsa_files[@]}"; do
    local filename=${fsa_files[i]}
    local partname=$(basename "$filename" .fsa)
    local device="/dev/$partname"
    if [[ $device == $root ]]; then
      showx "Note: Skipping $partname because it is the currently active partition."
      showx "To restore this partition, run this program from another partition."
    else
      partitions+=("$partname")
    fi
  done
  if [[ ${#partitions[@]} -eq 0 ]]; then
    showx "Error: No valid partitions available for restore."
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
arg_short=d:
arg_long=directory:
arg_opts=$(getopt --options "$arg_short" --long "$arg_long" --name "$0" -- "$@")
if [ $? != 0 ]; then
  show_syntax
  exit 1
fi

eval set -- "$arg_opts"
while true; do
  case "$1" in
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
  targetdisk="$1"
  shift 1
  if [[ ! -b "$targetdisk" ]]; then
    printx "No valid device was found for '$targetdisk'."
    exit
  fi
else
  show_syntax
fi

# echo "targetdisk=$targetdisk"
# echo "backupdevice=$backupdevice"
# echo "archivename=$archivename"

if [ -z $backupdevice ] || [ -z $targetdisk ]; then
  show_syntax
fi

if [[ "$EUID" != 0 ]]; then
  printx "This must be run as sudo.\n"
  exit 1
fi

# Initialize the log file
echo -n &> "$g_logfile"

mount_device_at_path "$backupdevice" "$g_backuppath"

if [ -z $archivename ]; then
  echo "Select an archive..."
  archivename=$(select_archive "$backupdevice" "$g_backuppath")
  if [ -z $archivename ]; then
    show "Operation cancelled"
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
readarray -t selected < <(select_restore_partitions "$archivepath" "$root_part")   

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
  echo "Details of the operation can be viewed in the file $g_logfile"
else
  printx "No partitions were selected for restore."
fi
