#!/bin/bash

## zfs-dr.sh
##
## Takes a full snapshot of all ZFS filesystems on the first of the month
## and dumps all previous snapshots created by this script. The snapshots
## are then exported with zfs-send into an archival folder, which is then
## compressed with 7-zip and encrypted with openssl.
##
## On the first day of every week (Sunday), takes a snapshot of all ZFS
## filesystems. These are exported as incremental snopshots, based off the
## previous monthly or weekly snapshot (whichever was done last). Any
## existing daily snapshots are deleted.
##
## On the subsequent days of every week (M-Sat), takes a snapshot of all
## ZFS filesystems. These are exported as incremental snapshots, based off
## the previous monthly, weekly, or daily snapshot (whichever was done
## last).


### USER-EDITABLE VARIABLES
zfs_root_pool="data"
zfsdr_snap_prefix="zfs-dr"
main_backup_dir="/backup"
openssl_enc_pw_file="/root/key/zfs-dr.key"


### FUNCTIONS
create_temp_dir() {
  zfsdr_temp_dir=$(mktemp -p "$main_backup_dir" -d)
}

compress_archive() {
  local current_working_dir=$(pwd)
  cd "$zfsdr_temp_dir"
  7za a -t7z -w"$zfsdr_temp_dir" -mx=9 -ms=off -m0=LZMA2 -mf=off -mmt=on "$current_archive".7z "$current_archive"
  cd "$current_working_dir"
}

encrypt_archive() {
  openssl enc -aes-256-ctr -in "$zfsdr_temp_dir"/"$current_archive".7z -out "$zfsdr_temp_dir"/"$current_archive".7z.enc -pass file:"$openssl_enc_pw_file" -salt 
}

move_archive_to_backup() {
  mv "$zfsdr_temp_dir"/"$current_archive".7z.enc "$main_backup_dir"/"$current_archive".7z.enc
  rm -r "$zfsdr_temp_dir"
}

do_monthly_snap() {
  zfs snapshot -r "$zfs_root_pool"@"$zfsdr_snap_prefix"_newmonthly
  dump_monthly_snaps
  zfs rename -r "$zfs_root_pool"@"$zfsdr_snap_prefix"_newmonthly "$zfsdr_snap_prefix"_monthly

  create_temp_dir

  current_archive="$zfsdr_snap_prefix"_monthly_`date +%Y%m`

  zfs send -R "$zfs_root_pool"@"$zfsdr_snap_prefix"_monthly > "$zfsdr_temp_dir"/"$current_archive"

  compress_archive
  encrypt_archive
  dump_monthly_archives
  move_archive_to_backup
}

do_weekly_snap() {
  zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_monthly$
  if [[ $? -eq 1 ]]; then
    do_monthly_snap
    return
  fi

  get_current_week
  zfs snapshot -r "$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$current_week"
  dump_daily_snaps

  if [[ $previous_week -ne 0 ]]; then
    zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$previous_week"$
    if [[ $? -eq 1 ]]; then
      previous_week=0
    fi
  fi

  create_temp_dir

  current_archive="$zfsdr_snap_prefix"_weekly_`date +%Y%m%d`

  if [[ $previous_week -eq 0 ]];then
    zfs send -R -i "$zfs_root_pool"@"$zfsdr_snap_prefix"_monthly "$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$current_week" > "$zfsdr_temp_dir"/"$current_archive"
  else
    zfs send -R -i "$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$previous_week" "$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$current_week" > "$zfsdr_temp_dir"/"$current_archive"
  fi

  compress_archive
  encrypt_archive
  dump_daily_archives
  move_archive_to_backup
}

do_daily_snap() {
  zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_monthly$
  if [[ $? -eq 1 ]]; then
    do_monthly_snap
    return
  fi

  get_current_week
  current_day=`date +%w`
  previous_day=$current_day - 1
  zfs snapshot -r "$zfs_root_pool"@"$zfsdr_snap_prefix"_daily"$current_day"

  create_temp_dir

  current_archive="$zfsdr_snap_prefix"_daily_`date +%Y%m%d`

  zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_daily"$previous_day"$
  if [[ $? -eq 0 ]]; then
    local prev_day_exists=1
  fi

  zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$current_week"$
  if [[ $? -eq 0 ]]; then
    local curr_week_exists=1
  fi

  zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$previous_week"$
  if [[ $? -eq 0 ]]; then
    local prev_week_exists=1
  fi

  if [[ $previous_day -ne 0 && $prev_day_exists -eq 1 ]]; then
    zfs send -R -i "$zfs_root_pool"@"$zfsdr_snap_prefix"_daily"$previous_day" "$zfs_root_pool"@"$zfsdr_snap_prefix"_daily"$current_day" > "$zfsdr_temp_dir"/"$current_archive"
  elif [[ $curr_week_exists -eq 1 ]]; then
    zfs send -R -i "$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$current_week" "$zfs_root_pool"@"$zfsdr_snap_prefix"_daily"$current_day" > "$zfsdr_temp_dir"/"$current_archive"
  elif [[ $previous_week -ne 0 && $prev_week_exists -eq 1 ]]; then
    zfs send -R -i "$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$previous_week" "$zfs_root_pool"@"$zfsdr_snap_prefix"_daily"$current_day" > "$zfsdr_temp_dir"/"$current_archive"
  else
    zfs send -R -i "$zfs_root_pool"@"$zfsdr_snap_prefix"_monthly "$zfs_root_pool"@"$zfsdr_snap_prefix"_daily"$current_day" > "$zfsdr_temp_dir"/"$current_archive"
  fi

  compress_archive
  encrypt_archive
  move_archive_to_backup
}

dump_daily_snaps() {
  zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_daily[1-6]$ | xargs -n 1 zfs destroy -r
}

dump_weekly_snaps() {
  dump_daily_snaps
  zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly[1-5]$ | xargs -n 1 zfs destroy -r
}

dump_monthly_snaps() {
  dump_weekly_snaps
  zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_monthly$ | xargs -n 1 zfs destroy -r
}

dump_daily_archives() {
  rm "$main_backup_dir"/*_daily_*
}

dump_weekly_archives() {
  dump_daily_archives
  rm "$main_backup_dir"/*_weekly_*
}

dump_monthly_archives() {
  dump_weekly_archives
  rm "$main_backup_dir"/*_monthly_*
}

get_current_week() {
  if [[ `date +%d` -ge 2 && `date +%d` -le 8 ]]; then
    current_week=1
  elif [[ `date +%d` -ge 9 && `date +%d` -le 15 ]]; then
    current_week=2
  elif [[ `date +%d` -ge 16 && `date +%d` -le 22 ]]; then
    current_week=3
  elif [[ `date +%d` -ge 23 && `date +%d` -le 29 ]]; then
    current_week=4
  else
    current_week=5
  fi

  previous_week=$current_week - 1
}



### MAIN SCRIPT

if [[ ! -d $main_backup_dir ]]; then
  echo "Backup root directory $main_backup_dir not found, exiting..."
  exit 255
fi

if [[ `date +%d` -eq 1 ]]; then
  do_monthly_snap
elif [[ `date +%w` -eq 0 ]]; then
  do_weekly_snap
else
  do_daily_snap
fi

