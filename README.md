# zfs-dr

ZFS-DR is a script originally designed to facilitate the full backup of a ZFS pool in case of catastrophic server loss (a "disaster recovery" scenario). The backup cycle is a standard grandparent-parent-child setup, with the monthly backup running on the first of the month, weekly backups on every Sunday thereafter, and daily backups on every other day.

An entire ZFS pool is targeted for backup, using a recursive snapshot to capture all datasets. The monthly snapshot is a full export, with weekly snapshots being exported as an incremental difference from monthly to weekly to weekly. Daily snapshots are exported as an incremental difference from the most recent snapshot (monthly, weekly, or daily). Each new weekly snapshot automatically removes all current daily snapshots, and each monthly snapshot automatically removes all snapshots taken.

Exported snapshots can optionally be compressed (using 7-Zip) and/or encrypted (using an OpenSSL key file) before being moved to storage. The script will by default automatically delete the exported archives on the same schedule as the snapshots, but this can be disabled if you would prefer to keep several cycles of archives in storage (and manage them separately).

Configuration of the script is controlled by several variables at the top of the script.

## Dependencies

Obviously, ZFS will need to be installed. Beyond that, other external programs used include:
- `date`
- `xargs`
- `mktemp`
- `grep`
- `openssl`
- `7za`

The first five probably come as part of a standard install of your preferred distro, with 7-Zip being the only additional package required (and only if using the optional compression step).

## Usage

Set the configuration variables in the top of the script according to your requirements. Then add a line to your crontab (for a user who has permission to create and send snapshots, and write to the desired areas on disk) to run the `zfs-dr.sh` script daily.

## Roadmap

Future goals for development (in no particular order):
- Put the configuration variables into a separate config file with better inline documentation.
- Use `cp`/`rm` instead of `mv` to transfer the completed archive (avoid permissions errors when transferring across filesystem boundaries)
- Add debug/verbose switch to enable xtrace and additional messages indicating program flow points
- Use lzip for compression rather than 7-Zip.
- Add the -pbkdf2 argument for openssl encryption.
- When checking the archive files on disk, warn if they are zero-byte files (not properly exported).
