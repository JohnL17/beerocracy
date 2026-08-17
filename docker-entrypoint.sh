#!/bin/sh
#
# Makes the data directory writable before handing over to the release.
#
# SQLite needs to create the database file and, alongside it, the -wal and -shm
# files — so the *directory* has to be writable, not just the database. A bind
# mount arrives owned by whoever created it on the host, and when `./data` does
# not exist yet Docker creates it as root, which an unprivileged container user
# cannot write to. Named volumes do not have this problem, which is exactly why
# it is easy to miss.

set -e

data_dir=$(dirname "${DATABASE_PATH:-/data/beerocracy.db}")

if [ "$(id -u)" = "0" ]; then
  # Started as root: take ownership of the data directory, then drop straight
  # to the unprivileged user. Nothing in the application ever runs as root.
  mkdir -p "$data_dir"
  chown -R beerocracy:beerocracy "$data_dir"
  exec gosu beerocracy "$0" "$@"
fi

# Unprivileged, either because we just dropped to it or because the operator
# pinned `user:` in compose. Prove we can actually write before the release
# starts, so a permissions problem reads as one line rather than as a database
# pool timeout twenty lines deep.
if ! mkdir -p "$data_dir" 2>/dev/null || ! touch "$data_dir/.writable" 2>/dev/null; then
  echo "beerocracy: cannot write to $data_dir as uid $(id -u):$(id -g)." >&2
  echo "" >&2
  echo "  If you bind-mount a host directory, hand it to this user:" >&2
  echo "      chown -R $(id -u):$(id -g) ./data" >&2
  echo "" >&2
  echo "  Or remove any 'user:' override and let the container sort it out." >&2
  exit 1
fi
rm -f "$data_dir/.writable"

exec "$@"
