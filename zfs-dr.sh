#!/usr/bin/env bash

## zfs-dr.sh
##
## Takes a full snapshot of all ZFS filesystems on the first of the month
## and dumps all previous snapshots created by this script. The snapshots
## are then exported with zfs-send into an archival folder, which is then
## compressed with 7-zip and encrypted with openssl.
##
## On the first day of every week (Sunday), takes a snapshot of all ZFS
## filesystems. These are exported as incremental snapshots, based off the
## previous monthly or weekly snapshot (whichever was done last). Any
## existing daily snapshots are deleted.
##
## On the subsequent days of every week (M-Sat), takes a snapshot of all
## ZFS filesystems. These are exported as incremental snapshots, based off
## the previous monthly, weekly, or daily snapshot (whichever was done
## last).
##
##
##
##     Copyright (C) 2018 Lance Hathaway
##
##    This program is free software: you can redistribute it and/or modify
##    it under the terms of the GNU Lesser General Public License as published by
##    the Free Software Foundation, either version 3 of the License, or
##    (at your option) any later version.
##
##    This program is distributed in the hope that it will be useful,
##    but WITHOUT ANY WARRANTY; without even the implied warranty of
##    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
##    GNU Lesser General Public License for more details.
##
##    You should have received a copy of the GNU Lesser General Public License
##    along with this program.  If not, see <https://www.gnu.org/licenses/>.


### USER-EDITABLE VARIABLES

# The root ZFS pool to back up
zfs_root_pool="data"

# The prefix to use for ZFS snapshots created by this script
zfsdr_snap_prefix="zfs-dr"

# The directory where the completed archives should be stored
main_backup_dir="/backup"

# If false, the script will exit immediately after taking snapshots if the
# main backup directory is unavailable. If true, the script will export the
# snapshots and do any configured compression / encryption, but will not move the
# finished archive file to the main storage.
continue_without_main_backup_dir="false"

# The directory where temporary files should be stored
main_temp_dir="/backup"

# Should exported archives be compressed?
compress_backup="true"

# Should exported archives be encrypted?
encrypt_backup="true"

# Set the password file which will be used for encryption
openssl_enc_pw_file="/root/key/zfs-dr.key"

# Should intermediate steps be deleted immediately after use (could be
# useful if the main temp directory is on a space-constrained filesystem)
delete_intermediate_steps_immediately="false"

# Allow this script to automatically delete old archive files from
# previous backup cycles?
auto_delete_old_archives="true"


### FUNCTIONS
throw_error(){
  echo "ERROR: ${1}" >&2
  exit 64
}

throw_warning(){
  echo "WARNING: ${1}" >&2
}

prerequisite_check() {
  /sbin/zfs -? > /dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    throw_error "ZFS command not found, exiting..."
  fi

  if [[ ! -d $main_backup_dir ]]; then
    if [[ "$continue_without_main_backup_dir" == "true" ]]; then
      throw_warning "Backup storage directory $main_backup_dir not found, continuing anyway..."
    else
      throw_warning "Backup storage directory $main_backup_dir not found, will do snapshots and exit..."
    fi
  fi

  if [[ ! -d $main_temp_dir ]]; then
    throw_warning "Scratch directory $main_temp_dir not found, will do snapshots and exit..."
  fi

  command -v date > /dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    throw_error "date utility not found."
  fi

  xargs --version
  if [[ $? -ne 0 ]]; then
    throw_error "xargs utility not found."
  fi

  command -v mktemp > /dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    throw_error "mktemp utility not found."
  fi

  command -v grep > /dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    throw_error "grep utility not found."
  fi

  if [[ $encrypt_backup = "true" ]]; then
    openssl version > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      throw_error "openssl utility not found."
    fi
  fi

  if [[ $compress_backup = "true" ]]; then
    7za > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      throw_error "7za utility not found."
    fi
  fi
}

create_temp_dir() {
  zfsdr_temp_dir=$(mktemp -p "$main_temp_dir" -t "$zfsdr_snap_prefix".XXXXXXXX -d)
}

compress_archive() {
  if [[ "$compress_backup" == "true" ]]; then
    if [[ ! -f "$zfsdr_temp_dir"/"$current_archive" ]]; then
      throw_error "Unable to determine what archive to compress!"
    fi

    local current_working_dir=$(pwd)
    cd "$zfsdr_temp_dir"
    7za a -t7z -w"$zfsdr_temp_dir" -mx=9 -ms=off -m0=LZMA2 -mf=off -mmt=on "$current_archive.7z" "$current_archive"

    if [[ "$delete_intermediate_steps_immediately" == "true" ]]; then
      rm "$current_archive"
    fi    

    current_archive="$current_archive.7z"
    cd "$current_working_dir"
  fi
}

encrypt_archive() {
  if [[ "$encrypt_backup" == "true" ]]; then
    if [[ -f "$zfsdr_temp_dir/$current_archive" ]]; then
      openssl enc -aes-256-ctr -pbkdf2 -in "$zfsdr_temp_dir/$current_archive" -out "$zfsdr_temp_dir/$current_archive.enc" -pass file:"$openssl_enc_pw_file" -salt
      if [[ "$delete_intermediate_steps_immediately" == "true" ]]; then
        rm "$zfsdr_temp_dir/$current_archive"
      fi
    else
      throw_error "Unable to determine what archive to encrypt!"
    fi

    current_archive="$current_archive.enc"

  fi
}

move_archive_to_backup() {
  if [[ -d $main_backup_dir ]]; then
    if [[ -f "$zfsdr_temp_dir/$current_archive" ]]; then
      cp --no-preserve=ownership "$zfsdr_temp_dir/$current_archive" "$main_backup_dir/$current_archive"
      rm -r "$zfsdr_temp_dir"
    else
      throw_error "Unable to locate archive to move to storage!"
    fi

  else
    throw_error "Backup storage directory $main_backup_dir not found! Admin must move completed archive $current_archive from temp dir $zfsdr_temp_dir to storage manually."
  fi
}

check_for_archive() {
  for f in "$main_backup_dir"/"$zfsdr_snap_prefix"_${1}_${2}*; do
    if [[ ! -f "$f" ]]; then
      for d in "$main_temp_dir"/"$zfsdr_snap_prefix".*; do
        if [[ -d "$d" && "$d" != "$zfsdr_temp_dir" ]]; then
          throw_warning "Missing ${1} archive detected, but at least one other scratch directory is still processing; continuing..."
        break 2
        fi
      done
      throw_warning "Missing ${1} archive detected, and NO other scratch directories exist--admin attention required! Continuing..."
      break
    fi
  done
}

export_zfs_incremental_snapshot() {
  /sbin/zfs send -R -i "$zfs_root_pool"@"$zfsdr_snap_prefix"_${1} "$zfs_root_pool"@"$zfsdr_snap_prefix"_${2} > "$zfsdr_temp_dir"/"$current_archive"
}

do_monthly_snap() {
  /sbin/zfs snapshot -r "$zfs_root_pool"@"$zfsdr_snap_prefix"_newmonthly
  dump_monthly_snaps
  /sbin/zfs rename -r "$zfs_root_pool"@"$zfsdr_snap_prefix"_newmonthly "$zfsdr_snap_prefix"_monthly

  if [[ ! -d $main_backup_dir && "$continue_without_main_backup_dir" != "true" ]]; then
    throw_error "Snapshot created, exiting because $main_backup_dir is not available..."
  fi

  if [[ -d $main_temp_dir ]]; then
    create_temp_dir

    current_archive="$zfsdr_snap_prefix"_monthly_`date +%Y%m`

    /sbin/zfs send -R "$zfs_root_pool"@"$zfsdr_snap_prefix"_monthly > "$zfsdr_temp_dir"/"$current_archive"

    compress_archive
    encrypt_archive
    if [[ "$auto_delete_old_archives" == "true" ]]; then
      dump_monthly_archives
    fi
    move_archive_to_backup
  else
    throw_error "Scratch directory $main_temp_dir not found! Snapshot created, but unable to continue with archive export..."
  fi
}

do_weekly_snap() {
  /sbin/zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_monthly$
  if [[ $? -eq 1 ]]; then
    throw_warning "Missing monthly snapshot detected; performing monthly snapshot instead."
    do_monthly_snap
    return
  fi

  get_current_week
  /sbin/zfs snapshot -r "$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$current_week"
  dump_daily_snaps

  if [[ ! -d $main_backup_dir && "$continue_without_main_backup_dir" != "true" ]]; then
    throw_error "Snapshot created, exiting because $main_backup_dir is not available..."
  fi

  # If the previous week was zero or less, then we don't expect to find any previous weekly snapshots.
  # Check the previous weeks until we find one that exists, or we run out of weeks to check.
  local ret
  while [[ $previous_week -gt 0 ]]; do
    /sbin/zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$previous_week"$
    ret=$?
    if [[ $ret -eq 1 ]]; then
      throw_warning "Missing snapshot weekly$previous_week"
      (( previous_week-- ))
    elif [[ $ret -eq 0 ]]; then
      break
    fi
  done
  unset ret

  if [[ -d $main_temp_dir ]]; then
    create_temp_dir

    current_archive="$zfsdr_snap_prefix"_weekly_`date +%Y%m%d`

    check_for_archive monthly `date +%Y%m`

    if [[ $previous_week -lt 1 ]];then
      export_zfs_incremental_snapshot monthly weekly"$current_week"
    else
      local rewindweeks=$(( $current_week - $previous_week ))
      local rewinddays=$(( $rewindweeks * 7 ))
      local prevarchivedate=$(( $start_of_week - $rewinddays ))
      if [[ $prevarchivedate -lt 10 ]]; then
        prevarchivedate="0$prevarchivedate"
      fi
      check_for_archive weekly `date +%Y%m`$prevarchivedate
      export_zfs_incremental_snapshot weekly"$previous_week" weekly"$current_week"
    fi

    compress_archive
    encrypt_archive
    if [[ "$auto_delete_old_archives" == "true" ]]; then
      dump_daily_archives
    fi
    move_archive_to_backup
  else
    throw_error "Scratch directory $main_temp_dir not found! Snapshot created, but unable to continue with archive export..."
  fi
}

do_daily_snap() {
  /sbin/zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_monthly$
  if [[ $? -eq 1 ]]; then
    throw_warning "Missing monthly snapshot detected; performing monthly snapshot instead."
    do_monthly_snap
    return
  fi

  get_current_week

  # If we haven't had a weekly snapshot yet, than don't look for one.
  if [[ $current_week -gt 0 ]]; then
    /sbin/zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly"$current_week"$
    if [[ $? -eq 1 ]]; then
      throw_warning "Missing weekly snapshot detected; performing weekly snapshot instead."
      do_weekly_snap
      return
    fi
  fi

  current_dow=`date +%w`

  /sbin/zfs snapshot -r "$zfs_root_pool"@"$zfsdr_snap_prefix"_daily"$current_dow"

  if [[ ! -d $main_backup_dir && "$continue_without_main_backup_dir" != "true" ]]; then
    throw_error "Snapshot created, exiting because $main_backup_dir is not available..."
  fi

  previous_dow=$(( $current_dow - 1 ))
  previous_day=$(( `date +%e` - 1 ))

  # If the previous dow was zero or the previous day was one, then we don't expect to find any previous
  # daily snapshots.
  # Check the previous days until we find one that exists, or we run out of days to check.
  # Note that dow can reach one (we've reached the first possible daily snapshot in the week) OR day
  # can reach two (we've reached the first possible daily backup in the month), and either condition
  # should stop the check.
  local ret
  while [[ $previous_dow -gt 0 && $previous_day -gt 1 ]]; do
    /sbin/zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_daily"$previous_dow"$
    ret=$?
    if [[ $ret -eq 1 ]]; then
      throw_warning "Missing snapshot daily$previous_dow"
      (( previous_dow-- ))
      (( previous_day-- ))
    elif [[ $ret -eq 0 ]]; then
      break
    fi
  done
  unset ret

  if [[ -d $main_temp_dir ]]; then
    create_temp_dir

    current_archive="$zfsdr_snap_prefix"_daily_`date +%Y%m%d`

    check_for_archive monthly `date +%Y%m`
    if [[ $current_week -gt 0 ]]; then
      if [[ $start_of_week -lt 10 ]]; then
        start_of_week="0$start_of_week"
      fi
      check_for_archive weekly `date +%Y%m`$start_of_week
    fi

    # If previous day of week is greater than zero (and we didn't reach the beginning of the month),
    # export based on the previous daily.
    # If previous day of week reached zero and current week is greater than zero, export based on the
    # current weekly snapshot. (If we reached the beginning of the month before reaching the beginning
    # of the week, we're automatically in week zero.)
    # If we're in week zero, export based on the monthly snapshot.
    if [[ $previous_dow -gt 0 && $previous_day -gt 1 ]]; then
      local rewind=$(( $current_dow - $previous_dow ))
      local prevarchivedate=$(( `date +%e` - $rewind ))
      if [[ $prevarchivedate -lt 10 ]]; then
        prevarchivedate="0$prevarchivedate"
      fi
      check_for_archive daily `date +%Y%m`$prevarchivedate
      export_zfs_incremental_snapshot daily"$previous_dow" daily"$current_dow"
    elif [[ $current_week -gt 0 ]]; then
      export_zfs_incremental_snapshot weekly"$current_week" daily"$current_dow"
    else
      export_zfs_incremental_snapshot monthly daily"$current_dow"
    fi

    compress_archive
    encrypt_archive
    move_archive_to_backup
  else
    throw_error "Scratch directory $main_temp_dir not found! Snapshot created, but unable to continue with archive export..."
  fi
}

dump_daily_snaps() {
  /sbin/zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_daily[1-6]$ | xargs -n 1 /sbin/zfs destroy -r
}

dump_weekly_snaps() {
  dump_daily_snaps
  /sbin/zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_weekly[1-5]$ | xargs -n 1 /sbin/zfs destroy -r
}

dump_monthly_snaps() {
  dump_weekly_snaps
  /sbin/zfs list -t snapshot -o name | grep ^"$zfs_root_pool"@"$zfsdr_snap_prefix"_monthly$ | xargs -n 1 /sbin/zfs destroy -r
}

dump_daily_archives() {
  if [[ -d $main_backup_dir ]]; then
    rm "$main_backup_dir"/*_daily_*
  else
    throw_warning "Backup storage directory $main_backup_dir not found! Unable to remove archive files..."
  fi
}

dump_weekly_archives() {
  if [[ -d $main_backup_dir ]]; then
    dump_daily_archives
    rm "$main_backup_dir"/*_weekly_*
  else
    throw_warning "Backup storage directory $main_backup_dir not found! Unable to remove archive files..."
  fi
}

dump_monthly_archives() {
  if [[ -d $main_backup_dir ]]; then
    dump_weekly_archives
    rm "$main_backup_dir"/*_monthly_*
  else
    throw_warning "Backup storage directory $main_backup_dir not found! Unable to remove archive files..."
  fi
}

get_current_week() {
  eval start_of_week=$(( `date +%e` - `date +%w` ))
  if [[ $start_of_week -le 1 ]]; then
    current_week=0
  elif [[ $start_of_week -ge 2 && $start_of_week -le 8 ]]; then
    current_week=1
  elif [[ $start_of_week -ge 9 && $start_of_week -le 15 ]]; then
    current_week=2
  elif [[ $start_of_week -ge 16 && $start_of_week -le 22 ]]; then
    current_week=3
  elif [[ $start_of_week -ge 23 && $start_of_week -le 29 ]]; then
    current_week=4
  else
    current_week=5
  fi

  previous_week=$(( $current_week - 1 ))
}



### MAIN SCRIPT

prerequisite_check

if [[ `date +%e` -eq 1 ]]; then
  do_monthly_snap
elif [[ `date +%w` -eq 0 ]]; then
  do_weekly_snap
else
  do_daily_snap
fi

