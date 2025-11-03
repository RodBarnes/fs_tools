# fs_tools
A collection of `bash` scripts to create partition-level backups using fsarchiver.

## ts_backup.sh
Usage: `sudo fs_backup <device> [-d] [description]`

Creates a full archive of that includes the selected partitions.

## fs_delete.sh
Usage: `sudo fs_delete <backup_device>`

Lists the archives (created by `fs_backup`) found on the designated device and allows selecting one for deletion.

## fs_list.sh
Usage: `sudo fs_list <backup_device>`

Lists the archvies (created by `fs_backup`) found on the designated device.

## fs_restore.sh
Usage: `sudo fs_restore <backup_device> <restore_device> [-d] [snapshot_name]`

Restores an archive (created by `fs_backup`) and allows selecting the specific partitions to restore.  Allows for backing up active (online) partitions.  Best use is to run `fs_restore` from a server's recovery partition or live media.

