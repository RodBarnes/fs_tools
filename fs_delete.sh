#!/usr/bin/env bash

set -eo pipefail

source /usr/local/lib/colors

backuppath=/mnt/backup
descfile=comment.txt

function printx {
  printf "${YELLOW}$1${NOCOLOR}\n"
}

function readx {
  printf "${YELLOW}$1${NOCOLOR}"
  read -p "" $2
}

function show_syntax {
  echo "Delete a backup created by fs_backup"
  echo "Syntax: $0 <backup_device>"
  echo "Where:  <backup_device> is the device containing the backup files."
  exit
}

function mount_device_at_path {
  local device=$1 mount=$2

  # Ensure mount point exists
  if [ ! -d $mount ]; then
    sudo mkdir -p $mount
    if [ $? -ne 0 ]; then
      printx "Unable to locate or create '$mount'." >&2
      exit 2
    fi
  fi

  # Attempt to mount the device
  sudo mount $device $mount
  if [ $? -ne 0 ]; then
    printx "Unable to mount the backup backupdevice '$device'." >&2
    exit 2
  fi

  # Ensure the directory structure exists
  if [ ! -d "$mount/fs" ]; then
    sudo mkdir "$mount/fs"
    if [ $? -ne 0 ]; then
      printx "Unable to locate or create '$mount/fs'." >&2
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

function select_archive {
  local path=$1
  
  local name archives=()
  
  # Get the archives
  while IFS= read -r archive; do
    if [ -f "$path/fs/$archive/$descfile" ]; then
      comment=$(cat "$path/fs/$archive/$descfile")
    else
      comment="<no desc>"
    fi
    archives+=("${archive}: $comment")
  done < <( ls -1 "$path/fs" )

  # Get the count of options
  local count="${#archives[@]}"

  # Increment count to include the cancel
  ((count++))

  COLUMNS=1
  select selection in "${archives[@]}" "Cancel"; do
    if [[ "$REPLY" =~ ^[0-9]+$ && "$REPLY" -ge 1 && "$REPLY" -le $count ]]; then
      case ${selection} in
        "Cancel")
          # If the user decides to cancel...
          break
          ;;
        *)
          name=$selection
          break
          ;;
      esac
    else
      printx "Invalid selection. Please enter a number between 1 and $count.">&2
    fi
  done

  echo $name
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
