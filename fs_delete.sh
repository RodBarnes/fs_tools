#!/usr/bin/env bash

set -eo pipefail

source /usr/local/lib/colors

backuppath=/mnt/backup

function printx {
  printf "${YELLOW}$1${NOCOLOR}\n"
}

function readx {
  printf "${YELLOW}$1${NOCOLOR}"
  read -p "" $2
}

function show_syntax {
  echo "List backups created by fs_backup"
  echo "Syntax: $0 <backup_device>"
  echo "Where:  <backup_device> is the device containing the backup files."
  exit
}

function mount_backup_device {
  # Ensure mount point exists
  if [ ! -d $backuppath ]; then
    sudo mkdir -p $backuppath #&> /dev/null
    if [ $? -ne 0 ]; then
      printx "Unable to locate or create '$backuppath'."
      exit 2
    fi
  fi

  # Attempt to mount the device
  sudo mount $backupdevice $backuppath #&> /dev/null
  if [ $? -ne 0 ]; then
    printx "Unable to mount the backup backupdevice '$backupdevice'."
    exit 2
  fi

  # Ensure the directory structure exists
  if [ ! -d "$backuppath/fs" ]; then
    sudo mkdir "$backuppath/fs" $&> /dev/null
    if [ $? -ne 0 ]; then
      printx "Unable to locate or create '$backuppath/fs'."
      exit 2
    fi
  fi
}

function unmount_backup_device {
  # Unmount if mounted
  if [ -d "$backuppath/fs" ]; then
    sudo umount $backuppath
  fi
}

function select_archive () {
  # Get the archvies and allow selecting
  echo "Listing backup files..."

  # Get the archives
  unset archives
  while IFS= read -r archive; do
    archives+=("${archive}")
  done < <( ls -1 "$backuppath/fs" )


  # Get the count of options
  count="${#archives[@]}"

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
          archivename=$selection
          break
          ;;
      esac
    else
      printx "Invalid selection. Please enter a number between 1 and $count."
    fi
  done

}

# --------------------
# ------- MAIN -------
# --------------------

trap unmount_backup_device EXIT

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

mount_backup_device

select_archive

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

unmount_backup_device
