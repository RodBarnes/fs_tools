#!/usr/bin/env bash

# Create a backup of one or more partitions from a drive using fsarchiver

source /usr/local/lib/fs_shared

show_syntax() {
  echo "Create a backup of selected partitions using fsarchiver."
  echo "Syntax: $0 <backup_device> <source_disk> [-a|--include-active] [-c|--comment \"comment\"]"
  echo "Where:  <backup_device> can be a backupdevice designator (e.g., /dev/sdb6), a UUID, filesystem LABEL, or partition UUID"
  echo "        <source_disk> is the disk containing the partitions to be included in the backup."
  echo "        [-a|--include-active] is an option to force inclusion of partitions that are active; i.e., online."
  echo "        [-c|--comment \"comment\"] is the disk containing the partitions to be included in the backup."
  exit
}

backup_partition_table() {
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

backup_filesystem() {
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

  printf "Backing up $partition_device to archive..." >&2
  fsarchiver savefs $options "$fsa_file" "$partition_device" &>> "$g_outputfile"
  if [ $? -ne 0 ]; then
    printx "\nError: Failed to back up $partition_device" >&2
  fi
}

select_backup_partitions() {
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

supported_fstypes="ext2|ext3|ext4|xfs|btrfs|ntfs|vfat|fat16|fat32|reiserfs"
dateformat="+%Y%m%d_%H%M%S"

trap 'unmount_device_at_path "$g_backuppath"' EXIT

# Get the arguments
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
  arg="$1"
  shift 1
  device="${arg#/dev/}" # in case it is a device designator
  backupdevice="/dev/$(lsblk -ln -o NAME,UUID,PARTUUID,LABEL | grep "$device" | tr -s ' ' | cut -d ' ' -f1)"
  if [ -z $backupdevice ]; then
    printx "No valid device was found for '$device'."
    exit
  fi
  sourcedisk="$2"
  shift 1
  if [[ ! -b "$sourcedisk" ]]; then
    printx "Error: The specified source '$sourcedisk' is not a block device."
    exit
  fi
else
  show_syntax
fi

# echo "include-active=$include_active"
# echo "sourcedisk=$sourcedisk"
# echo "backupdevice=$backupdevice"
# echo "comment=$comment"
# exit

if [[ -z "$sourcedisk" || -z "$backupdevice" ]]; then
  show_syntax
fi

if [[ "$EUID" != 0 ]]; then
  printx "This must be run as sudo.\n"
  exit 1
fi

# Initialize the log file
echo &> "$g_outputfile"

mount_device_at_path "$backupdevice" "$g_backuppath"

# Get the active root partition
root_part=$(findmnt -n -o SOURCE /)

# Selected the partitions to backup
readarray -t selected < <(select_backup_partitions "$sourcedisk" "$root_part")   

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
archivepath="$g_backuppath/$g_backupdir/$(date $dateformat)_$(hostname -s)"
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
echo "Details of the operation can be viewed in the file /tmp/$g_outputfile"
