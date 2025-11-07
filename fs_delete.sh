#!/usr/bin/env bash

# Delete one or more fs_backups

set -eo pipefail

source fs_functions.sh

backuppath=/mnt/backup
descfile=comment.txt

show_syntax() {
  echo "Delete a backup created by fs_backup"
  echo "Syntax: $0 <backup_device>"
  echo "Where:  <backup_device> can be a device designator (e.g., /dev/sdb6), a UUID, filesystem LABEL, or partition UUID"
  exit
}

# --------------------
# ------- MAIN -------
# --------------------

trap 'unmount_device_at_path "$backuppath"' EXIT

# Get the arguments
if [ $# -ge 1 ]; then
  backupdevice=${1:-}
  shift 1
else
  show_syntax >&2
  exit 1
fi

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
archivename=$(select_archive "$backuppath")

if [ ! -z $archivename ]; then
  printx "This will completely DELETE the archive '$archivename' and is not recoverable."
  readx "Are you sure you want to proceed? (y/N) " yn
  if [[ $yn != "y" && $yn != "Y" ]]; then
    echo "Operation cancelled."
  else
    sudo rm -Rf $backuppath/fs/$archivename
    echo "'$archivename' has been deleted."
  fi
fi
