#!/bin/bash

set -euo pipefail

# Check for --include-active flag
INCLUDE_ACTIVE=false
if [[ $# -gt 0 && "$1" == "--include-active" ]]; then
  INCLUDE_ACTIVE=true
  shift
fi

DISK=${1:-}
BACKUP_DIR=${2:-}
if [[ -z "$DISK" || -z "$BACKUP_DIR" ]]; then
  echo "Usage: $0 [--include-active] <target_disk> <backup_dir>  # e.g., /dev/sda /mnt/backup/fs/2025-11-01_XX-XX-XX_boss-recovery"
  exit 1
fi

if [[ ! -b "$DISK" ]]; then
  echo "Error: $DISK not a block device."
  exit 1
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "Error: $BACKUP_DIR not a directory."
  exit 1
fi

# Check for partition table backup
if [[ ! -f "$BACKUP_DIR/pt-type" ]]; then
  echo "Error: $BACKUP_DIR/pt-type not found."
  exit 1
fi

PT_TYPE=$(cat "$BACKUP_DIR/pt-type")
if [[ "$PT_TYPE" != "gpt" && "$PT_TYPE" != "dos" ]]; then
  echo "Error: Invalid partition table type in $BACKUP_DIR/pt-type: $PT_TYPE"
  exit 1
fi

# Find available .fsa files
FSA_FILES=($(ls -1 "$BACKUP_DIR"/*.fsa 2>/dev/null))
if [[ ${#FSA_FILES[@]} -eq 0 ]]; then
  echo "Error: No .fsa files found in $BACKUP_DIR"
  exit 1
fi

# Get the active root partition
ROOT_PART=$(findmnt -n -o SOURCE /)

# Filter .fsa files, excluding the active partition unless --include-active is used
PARTS=()
MENU_ITEMS=()
for i in "${!FSA_FILES[@]}"; do
  FSA=${FSA_FILES[i]}
  PART=$(basename "$FSA" .fsa)
  PART_DEV="/dev/$PART"
  if [[ "$PART_DEV" == "$ROOT_PART" && "$INCLUDE_ACTIVE" == "false" ]]; then
    echo "Note: Skipping $PART (active root partition; use --include-active to restore)"
  else
    PARTS+=("$PART")
    MENU_ITEMS+=("$((i+1))" "$PART" "ON")
  fi
done

if [[ ${#PARTS[@]} -eq 0 ]]; then
  echo "Error: No valid partitions available for restoration"
  exit 1
fi

# Interactive selection with forced TERM
export TERM=xterm
SELECTION=$(whiptail --title "Select Partitions to Restore" --checklist "Choose one or more:" 15 60 ${#PARTS[@]} \
  "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
if [[ $? -ne 0 ]]; then
  echo "Cancelled: No restoration performed"
  exit 1
fi

echo "DEBUG: SELECTION='$SELECTION'"

# Convert selected tags (indices) to partition names
IFS=' ' read -ra SELECTED_TAGS <<< "$SELECTION"
echo "DEBUG: SELECTED_TAGS=${SELECTED_TAGS[@]}"
SELECTED=()
for tag in "${SELECTED_TAGS[@]}"; do
  tag_clean=${tag//\"/}
  if [[ $tag_clean =~ ^[0-9]+$ ]]; then
    index=$((tag_clean-1))
    if [[ $index -ge 0 && $index -lt ${#PARTS[@]} ]]; then
      SELECTED+=("${PARTS[index]}")
    else
      echo "Warning: Invalid tag '$tag_clean' ignored"
    fi
  else
    echo "Warning: Non-numeric tag '$tag_clean' ignored"
  fi
done
echo "DEBUG: SELECTED=${SELECTED[@]}"

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  echo "Error: No valid partitions selected"
  exit 1
fi

# Restore partition table
echo "Restoring partition table to $DISK ..."
if [[ "$PT_TYPE" == "gpt" ]]; then
  if [[ ! -f "$BACKUP_DIR/disk-pt.gpt" ]]; then
    echo "Error: $BACKUP_DIR/disk-pt.gpt not found."
    exit 1
  fi
  sgdisk --load-backup="$BACKUP_DIR/disk-pt.gpt" "$DISK"
elif [[ "$PT_TYPE" == "dos" ]]; then
  if [[ ! -f "$BACKUP_DIR/disk-pt.sf" ]]; then
    echo "Error: $BACKUP_DIR/disk-pt.sf not found."
    exit 1
  fi
  sfdisk "$DISK" < "$BACKUP_DIR/disk-pt.sf"
fi
echo "Partition table restoration complete."

# Inform kernel of partition table changes
partprobe "$DISK"

# Restore selected filesystems
for part in "${SELECTED[@]}"; do
  PART_DEV="/dev/$part"
  FSA="$BACKUP_DIR/$part.fsa"
  if [[ ! -f "$FSA" ]]; then
    echo "Error: $FSA not found, skipping $PART_DEV"
    continue
  fi
  if [[ ! -b "$PART_DEV" ]]; then
    echo "Error: $PART_DEV not a block device, skipping"
    continue
  fi
  # Check if partition is mounted
  MOUNT_POINT=$(awk -v part="$PART_DEV" '$1 == part {print $2}' /proc/mounts)
  if [[ -n "$MOUNT_POINT" ]]; then
    echo "Error: $PART_DEV is mounted at $MOUNT_POINT."
    read -p "Proceed and unmount it first? [y/N] " response
    if [[ "$response" =~ ^[yY]$ ]]; then
      if ! umount "$MOUNT_POINT"; then
        echo "Error: Failed to unmount $MOUNT_POINT, skipping $PART_DEV"
        continue
      fi
    else
      echo "Skipping restoration of $PART_DEV"
      continue
    fi
  fi
  if [[ "$PART_DEV" == "$ROOT_PART" ]]; then
    echo "Warning: Restoring active root partition $PART_DEV may cause system instability"
  fi
  echo "Restoring $FSA -> $PART_DEV"
  if ! fsarchiver restfs "$FSA" id=0,dest="$PART_DEV"; then
    echo "Error: Failed to restore $PART_DEV"
    continue
  fi
done

echo "✅ Restoration complete: $DISK"
lsblk -f "$DISK"