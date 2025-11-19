#!/usr/bin/env bash

# Delete one or more fs_backups

source /usr/local/lib/fs_shared.sh

show_syntax() {
  echo "Delete a backup created by fs_backup"
  echo "Syntax: $0 <backup_device>"
  echo "Where:  <backup_device> can be a device designator (e.g., /dev/sdb6), a UUID, filesystem LABEL, or partition UUID"
  exit
}

delete_archive() {
  local path=$1 name=$2

  showx "This will completely DELETE the archive '$name' and is not recoverable."
  readx "Are you sure you want to proceed? (y/N) " yn
  if [[ $yn != "y" && $yn != "Y" ]]; then
    show "Operation cancelled."
  else
    show "Deleting '$name'"
    sudo rm -Rf $path/$name
  fi
}

# --------------------
# ------- MAIN -------
# --------------------

trap 'unmount_device_at_path "$g_backuppath"' EXIT

# Get the arguments
if [ $# -ge 1 ]; then
  backupdevice="/dev/$(lsblk -ln -o NAME,UUID,PARTUUID,LABEL | grep "${1#/dev/}" | tr -s ' ' | cut -d ' ' -f1)"
else
  show_syntax
fi

# echo "backuppath=$g_backuppath"
# echo "backupdir=$g_backupdir"
# echo "backupdevice=$backupdevice"
# exit

verify_sudo

if [ ! -b $backupdevice ]; then
  printx "No valid backup device was found for '$device'."
  exit
fi

mount_device_at_path "$backupdevice" "$g_backuppath"

while true; do
  archivename=$(select_archive "$backupdevice" "$g_backuppath")
  if [ ! -z $archivename ]; then
    delete_archive "$g_backuppath/$g_backupdir" "$archivename"
  else
    exit
  fi
done



