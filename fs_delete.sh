#!/usr/bin/env bash

# Delete one or more fs_backups

source /usr/local/lib/fs_shared

show_syntax() {
  echo "Delete a backup created by fs_backup"
  echo "Syntax: $0 <backup_device>"
  echo "Where:  <backup_device> can be a device designator (e.g., /dev/sdb6), a UUID, filesystem LABEL, or partition UUID"
  exit
}

delete_archive() {
  local path=$1 name=$2

  printx "This will completely DELETE the archive '$name' and is not recoverable." >&2
  readx "Are you sure you want to proceed? (y/N) " yn
  if [[ $yn != "y" && $yn != "Y" ]]; then
    echo "Operation cancelled." >&2
  else
    echo "Deleting '$name'" >&2
    sudo rm -Rf $path/$name
  fi
}

# --------------------
# ------- MAIN -------
# --------------------

trap 'unmount_device_at_path "$g_backuppath"' EXIT

# Get the arguments
if [ $# -ge 1 ]; then
  arg="$1"
  shift 1
  device="${arg#/dev/}" # in case it is a device designator
  backupdevice="/dev/$(lsblk -ln -o NAME,UUID,PARTUUID,LABEL | grep "$device" | tr -s ' ' | cut -d ' ' -f1)"
  if [ -z $backupdevice ]; then
    printx "No valid device was found for '$device'."
    exit
  fi
else
  show_syntax
fi

# echo "backupdevice=$backupdevice"

if [[ -z "$backupdevice" ]]; then
  show_syntax
fi

if [[ "$EUID" != 0 ]]; then
  printx "This must be run as sudo.\n"
  exit 1
fi

mount_device_at_path "$backupdevice" "$g_backuppath"

echo "Listing backup files..."
while true; do
  archivename=$(select_archive "$g_backuppath")
  if [ ! -z $archivename ]; then
    delete_archive "$g_backuppath/$g_backupdir" "$archivename"
  else
    exit
  fi
done



