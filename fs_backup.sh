#!/usr/bin/env bash

# Create a backup of one or more partitions from a drive using fsarchiver

source /usr/local/lib/fs_shared.sh

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
      showx "Warning: $partition_device is mounted RW at $mount_point (live backup may have minor inconsistencies)"
    else
      show "Note: $partition_device is mounted read-only at $mount_point"
    fi
  fi

  local suffix=${partfs##$sourcedisk}
  local fsa_file="$path/$suffix.fsa"
  
  # show "sourcedisk##*/=${sourcedisk##*/}"
  # show "partition_device=$partition_device"
  # show "fsa_file=$fsa_file"
  # show "sourcedisk=$sourcedisk"
  # show "path=$path"
  # show "partition=$partition"
  # show "suffix=$suffix"
  # show "sourcedisk##*/=${sourcedisk##*/}"
  # read

  local options="-v -j$(nproc) -Z3"
  if $mounted_rw; then
    options="$options -A"
  fi

  show "Backing up $partition_device to archive..."
  fsarchiver savefs $options "$fsa_file" "$partition_device" &>> "$g_logfile"
  if [ $? -ne 0 ]; then
    showx "\nError: Failed to back up $partition_device"
  fi
}

select_backup_partitions() {
  local disk=$1 root=$2 active=$3
  # Get partitions, excluding unsupported filesystems and optionally the active partition

  # show "disk=$disk, root=$root, active=$active"
  
  local supported_fstypes="ext2|ext3|ext4|xfs|btrfs|ntfs|vfat|fat16|fat32|reiserfs"
  local partitions=()
  while IFS= read -r partition; do
    local fstype=$(lsblk -fno fstype "$partition" | head -n1)
    if [[ -n "$fstype" && $fstype =~ ^($supported_fstypes)$ ]]; then
      if [[ -z $active && "$partition" == "$root" ]]; then
        # Skip active partitions unless user specifically asks to include them
        show "Note: Skipping $partition (active root partition; use --include-active to back up)"
      else
        partitions+=("${partition#/dev/}")
      fi
    fi
  done < <(sfdisk --list "$disk" | awk '/^\/dev\// && $1 ~ /'"${disk##*/}"'[0-9]/ {print $1}' | sort)

  if [[ ${#partitions[@]} -eq 0 ]]; then
    showx "No supported filesystems found on $disk"
    exit 2
  fi

  # show "partitions..."
  # for i in "${!partitions[@]}"; do
  #     show "${partitions[i]}"
  # done
  # read

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
  backupdevice="/dev/$(lsblk -ln -o NAME,UUID,PARTUUID,LABEL | grep "${1#/dev/}" | tr -s ' ' | cut -d ' ' -f1)"
  sourcedisk="$2"
else
  show_syntax
fi

# echo "backuppath=$g_backuppath"
# echo "backupdir=$g_backupdir"
# echo "backupdevice=$backupdevice"
# echo "sourcedisk=$sourcedisk"
# echo "archivename=$archivename"
# echo "include-active=$include_active"
# echo "comment=$comment"
# exit

verify_sudo

if [ ! -b $backupdevice ]; then
  printx "No valid backup device was found for '$device'."
  exit
fi

if [[ ! -b "$sourcedisk" ]]; then
  printx "No valid source device was found for '$sourcedisk'."
  exit
fi

mount_device_at_path "$backupdevice" "$g_backuppath"

# Get the active root partition
root_part=$(findmnt -n -o SOURCE /)

# Selected the partitions to backup
readarray -t selected < <(select_backup_partitions "$sourcedisk" "$root_part" "$include_active")

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

archivename="$(date +%Y%m%d_%H%M%S)_$(hostname -s)"

# Initialize the log file
g_logfile="/tmp/$(basename $0)_$archivename.log"
echo -n &> "$g_logfile"

# Create backup directory and save partition table
archivepath="$g_backuppath/$g_backupdir/$archivename"
mkdir -p "$archivepath"

echo "Saving partition table to $archivepath/..."
backup_partition_table "$sourcedisk" "$archivepath"

echo "Backing up selected partitions to $archivepath/ ..."
for partition in "${selected[@]}"; do
  backup_filesystem "$partition" "$archivepath"
done

# Create description in the snapshot directory
echo "($(sudo du -sh $archivepath | awk '{print $1}')) $comment" > "$archivepath/$g_descfile"

echo "✅ Backup complete."
# ls -lh "$archivepath"
echo "Details of the operation can be viewed in the file $g_logfile"
