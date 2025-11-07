#!/usr/bin/env bash

set -eo pipefail

source fs_functions.sh

backuppath=/mnt/backup
backupdir="fs"
descfile=comment.txt

show_syntax() {
  echo "List backups created by fs_backup"
  echo "Syntax: $0 <backup_device>"
  echo "Where:  <backup_device> can be a backupdevice designator (e.g., /dev/sdb6), a UUID, filesystem LABEL, or partition UUID"
  exit
}

list_archives() {
  local device=$1 path=$2

  # Get the archives
  local archives=() note name
  local i=0
  while IFS= read -r name; do
    if [ $i -eq 0 ]; then
      echo "Backup files on $device" >&2
    fi
    if [ -f "$path/$name/$descfile" ]; then
      note=$(cat "$path/$name/$descfile")
    else
      note="<no desc>"
    fi
    echo "$name: $note" >&2
    ((i++))
  done < <( ls -1 "$path" )

  if [ $i -eq 0 ]; then
    printx "There are no backups on $device" >&2
  fi
}

# --------------------
# ------- MAIN -------
# --------------------

trap 'unmount_device_at_path "$backuppath"' EXIT

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
# echo "backuppath=$backuppath"

if [[ -z "$backupdevice" ]]; then
  show_syntax
fi

if [[ "$EUID" != 0 ]]; then
  printx "This must be run as sudo.\n"
  exit 1
fi

mount_device_at_path "$backupdevice" "$backuppath"
list_archives "$backupdevice" "$backuppath/$backupdir"

