#!/usr/bin/env bash

set -eo pipefail

source /usr/local/lib/colors

backuppath=/mnt/backup

function printx {
  printf "${YELLOW}$1${NOCOLOR}\n"
}

function show_syntax {
  echo "List backups created by fs_backup"
  echo "Syntax: $0 <backup_device>"
  echo "Where:  <backup_device> is the device containing the backup files."
  exit
}

function mount_device_at_path {
  local device=$1
  local mount=$2

  # Ensure mount point exists
  if [ ! -d $mount ]; then
    sudo mkdir -p $mount #&> /dev/null
    if [ $? -ne 0 ]; then
      printx "Unable to locate or create '$mount'."
      exit 2
    fi
  fi

  # Attempt to mount the device
  sudo mount $device $mount #&> /dev/null
  if [ $? -ne 0 ]; then
    printx "Unable to mount the backup backupdevice '$device'."
    exit 2
  fi

  # Ensure the directory structure exists
  if [ ! -d "$mount/fs" ]; then
    sudo mkdir "$mount/fs" $&> /dev/null
    if [ $? -ne 0 ]; then
      printx "Unable to locate or create '$mount/fs'."
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

function list_archives () {
  local path=$1

  # Get the archives
  unset archives
  while IFS= read -r name; do
    echo "$name"
    # archives+=("${LINE}")
  done < <( ls -1 "$path/fs" )
}

# --------------------
# ------- MAIN -------
# --------------------

trap 'unmount_device_at_path "$backuppath"' EXIT

# Get the arguments
backupdevice=${1:-}

# echo "backupdevice=$backupdevice"
# echo "backuppath=$backuppath"

if [[ -z "$backupdevice" ]]; then
  show_syntax
fi

if [[ ! -b "$backupdevice" ]]; then
  printx "Error: The specified backup device '$backupdevice' is not a block device."
  exit 2
fi

mount_device_at_path "$backupdevice" "$backuppath"

echo "Listing backup files..."
list_archives "$backuppath"

