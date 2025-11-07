#!/usr/bin/env bash

set -eo pipefail

source fs_functions.sh

backuppath=/mnt/backup
descfile=comment.txt

show_syntax() {
  echo "List backups created by fs_backup"
  echo "Syntax: $0 <backup_device>"
  echo "Where:  <backup_device> is the device containing the backup files."
  exit
}

list_archives() {
  local path=$1
  
  # Get the archives
  unset archives
  while IFS= read -r name; do
    if [ -f "$path/fs/$name/$descfile" ]; then
      comment=$(cat "$path/fs/$name/$descfile")
    else
      comment="<no desc>"
    fi
    echo "$name: $comment"
    # archives+=("${LINE}")
  done < <( ls -1 "$path/fs" )
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
list_archives "$backuppath"

