#!/usr/bin/env bash

# Shared code and variables for fs_tools

source /usr/local/lib/display
source /usr/local/lib/device

g_timestamp=$(date +%Y%m%d_%H%M%S)
g_descfile=comment.txt
g_logfile="/tmp/$(basename $0)_$g_timestamp.log"
g_backuppath=/mnt/backup
g_backupdir="fs"

select_archive() {
  local device=$1 path=$2
  
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

  if [ ${#archives[@]} -eq 0 ]; then
    showx "There are no backups on $device"
  else
    show "Listing backup files..."

    # Get the count of options and increment to include cancel
    local count="${#archives[@]}"
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
            name="${selection%%:*}"
            break
            ;;
        esac
      else
        showx "Invalid selection. Please enter a number between 1 and $count."
      fi
    done
  fi

  echo $name
}