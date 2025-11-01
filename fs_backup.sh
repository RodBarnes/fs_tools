#!/bin/bash

set -euo pipefail

# Check for --include-active flag
INCLUDE_ACTIVE=false
if [[ $# -gt 0 && "$1" == "--include-active" ]]; then
  INCLUDE_ACTIVE=true
  shift
fi

DISK=${1:-}
TARGET_DIR=${2:-}
if [[ -z "$DISK" || -z "$TARGET_DIR" ]]; then
  echo "Usage: $0 [--include-active] <source_disk> <target_dir>  # e.g., /dev/sda /mnt/usb"
  exit 1
fi

if [[ ! -b "$DISK" ]]; then
  echo "Error: $DISK not a block device."
  exit 1
fi

# Backup partition table function
backup_pt() {
  local disk=$1 imgdir=$2
  if fdisk -l "$disk" 2>/dev/null | grep -q '^Disklabel type: gpt'; then
    sgdisk --backup="$imgdir/disk-pt.gpt" "$disk"
    echo "gpt" > "$imgdir/pt-type"
  else
    sfdisk --dump "$disk" > "$imgdir/disk-pt.sf"
    echo "dos" > "$imgdir/pt-type"
  fi
  echo "Saved partition table to $imgdir/"
}

# List of filesystems supported by fsarchiver
SUPPORTED_FSTYPES="ext2|ext3|ext4|xfs|btrfs|ntfs|vfat|fat16|fat32|reiserfs"

# Get the active root partition
ROOT_PART=$(findmnt -n -o SOURCE /)

# Get partitions, excluding unsupported filesystems and optionally the active partition
PARTS=()
while IFS= read -r part; do
  FSTYPE=$(lsblk -fno FSTYPE "$part" | head -n1)
  if [[ -n "$FSTYPE" && $FSTYPE =~ ^($SUPPORTED_FSTYPES)$ ]]; then
    if [[ "$part" == "$ROOT_PART" && "$INCLUDE_ACTIVE" == "false" ]]; then
      echo "Note: Skipping $part (active root partition; use --include-active to back up)"
    else
      PARTS+=("$part")
    fi
  else
    echo "Note: Skipping $part (filesystem '$FSTYPE' not supported by fsarchiver)"
  fi
done < <(sfdisk --list "$DISK" | awk '/^\/dev\// && $1 ~ /'"${DISK##*/}"'[0-9]/ {print $1}' | sort)

if [[ ${#PARTS[@]} -eq 0 ]]; then
  echo "No supported filesystems found on $DISK"
  exit 1
fi

echo "DEBUG: Detected partitions with supported filesystems: ${PARTS[@]}"

# Prepare whiptail checklist items: "index" "partition" "state"
MENU_ITEMS=()
for i in "${!PARTS[@]}"; do
  MENU_ITEMS+=("$((i+1))" "${PARTS[i]}" "ON")
done

# Interactive selection with forced TERM
export TERM=xterm
SELECTION=$(whiptail --title "Select Partitions to Backup" --checklist "Choose one or more:" 15 60 ${#PARTS[@]} \
  "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
if [[ $? -ne 0 ]]; then
  echo "Cancelled: No backup directory created"
  exit 1
fi

echo "DEBUG: SELECTION='$SELECTION'"

# Convert selected tags (indices) to partition names
IFS=' ' read -ra SELECTED_TAGS <<< "$SELECTION"
echo "DEBUG: SELECTED_TAGS=${SELECTED_TAGS[@]}"
SELECTED=()
for tag in "${SELECTED_TAGS[@]}"; do
  # Remove quotes from tag
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

# Create backup directory and save partition table only after selection
IMGDIR="$TARGET_DIR/$(date +%Y-%m-%d_%H-%M-%S)_$(hostname -s)"
mkdir -p "$IMGDIR"
backup_pt "$DISK" "$IMGDIR"

echo "Backing up selected partitions to $IMGDIR/ ..."

for part in "${SELECTED[@]}"; do
  # Detect if mounted RW
  MOUNTED_RW=false
  MOUNT_POINT=$(awk -v part="$part" '$1 == part {print $2}' /proc/mounts)
  if [[ -n "$MOUNT_POINT" ]]; then
    if awk -v part="$part" '$1 == part {print $4}' /proc/mounts | grep -q '^rw'; then
      MOUNTED_RW=true
      echo "Warning: $part is mounted RW at $MOUNT_POINT (live backup may have minor inconsistencies)"
      echo "Consider remounting read-only with: mount -o remount,ro $MOUNT_POINT"
    else
      echo "Note: $part is mounted read-only at $MOUNT_POINT"
    fi
  fi

  SUFFIX=${part##$DISK}
  FSA="$IMGDIR/${DISK##*/}$SUFFIX.fsa"

  OPTS="-v -j$(nproc) -Z3"
  if $MOUNTED_RW; then
    OPTS="$OPTS -A"
  fi

  echo "Backing up $part -> $FSA"
  if ! fsarchiver savefs $OPTS "$FSA" "$part"; then
    echo "Error: Failed to back up $part"
    continue
  fi
done

echo "✅ Backup complete: $IMGDIR"
ls -lh "$IMGDIR"