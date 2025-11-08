#!/usr/bin/env bash

# Shared code and variables for fs_tools

source /usr/local/lib/color
source /usr/local/lib/device

g_descfile=comment.txt
g_outputfile="/tmp/$0.out"
g_backuppath=/mnt/backup
g_backupdir="fs"

select_archive() {
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
      printx "Invalid selection. Please enter a number between 1 and $count.">&2
    fi
  done

  echo $name
}