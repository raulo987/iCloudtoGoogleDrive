#!/bin/bash
# icloud-gdrive-sync.sh  —  Mac -> Google Drive one-way backup (rclone)
#
# One-way mirror of local ~/Documents and ~/Desktop to Google Drive.
# The name says "icloud" for historical reasons; the real data lives locally,
# not in iCloud Drive (com~apple~CloudDocs is just symlinks + legacy junk).
#
# ============================================================================
# SAFETY INVARIANT (the whole point of this design):
#   `rclone sync SOURCE DEST` reads SOURCE and only ever writes/deletes on DEST.
#   It NEVER writes to or deletes from SOURCE. Therefore:
#     * ~/Documents and ~/Desktop files can NOT be deleted by this script.
#     * iCloud is neither source nor destination — it is never touched.
#   Deletions happen only on the Google Drive side, diverted into a dated trash
#   dir (recoverable 90 days here, +30 days in Drive's own trash).
# ============================================================================
#
# Usage:
#   icloud-gdrive-sync.sh            run a backup
#   icloud-gdrive-sync.sh --dry-run  show what would change, transfer nothing
#   icloud-gdrive-sync.sh --verify   checksum-compare source vs backup (integrity)
#   icloud-gdrive-sync.sh --status   show when the last backup succeeded
#
# Configuration precedence: GUI config file  >  environment  >  built-in default.
# The GUI (menu-bar app) writes ~/.config/gdrive-backup/config; both it and this
# script read from there, so there is a single source of truth.
#
# Tunable keys (config file or environment):
#   RCLONE, DEST, TRASH, SRC_BASE, SOURCES, LOG, STATE_DIR,
#   MAX_DELETE, RETENTION, DRY_RUN, ALLOW_LOCAL_DEST (test seam — never in prod)
# SOURCES entries may be plain names (resolved under SRC_BASE) or absolute paths
# (backed up under their basename), e.g. SOURCES="Documents Desktop /Volumes/Work".

set -uo pipefail

# launchd hands us a minimal environment; make the tools we call resolvable.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ---- GUI-managed config file (optional) ------------------------------------
# Sourced before defaults so its values take effect; it only assigns the keys it
# contains. Tests point GDRIVE_BACKUP_CONFIG at a nonexistent path to keep full
# environment control and never pick up a real config.
CONFIG_FILE="${GDRIVE_BACKUP_CONFIG:-$HOME/.config/gdrive-backup/config}"
# shellcheck disable=SC1090  # runtime-provided, user-owned config path
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# ---- configuration (env-overridable; prod defaults) ------------------------
RCLONE="${RCLONE:-/opt/homebrew/bin/rclone}"
DEST="${DEST:-gdrive:Mac-Backup}"
TRASH="${TRASH:-gdrive:Mac-Backup-Trash}"
SRC_BASE="${SRC_BASE:-$HOME}"
SOURCES="${SOURCES:-Documents Desktop}"
LOG="${LOG:-$HOME/Library/Logs/gdrive-sync.log}"
STATE_DIR="${STATE_DIR:-$HOME/Library/Caches/gdrive-sync}"
MAX_DELETE="${MAX_DELETE:-500}"          # circuit breaker: abort a sync that would
                                         # delete more than this many files on DEST
RETENTION="${RETENTION:-90d}"            # how long trashed files are kept
DRY_RUN="${DRY_RUN:-0}"
ALLOW_LOCAL_DEST="${ALLOW_LOCAL_DEST:-0}"  # test seam: allow non-remote DEST
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}"  # rotate log past 10 MB
CHECKSUM="${CHECKSUM:-0}"                 # 1 = compare by checksum (thorough, slower)
                                         # not size+modtime — Drive's modtime is unreliable
BWLIMIT="${BWLIMIT:-}"                    # rclone --bwlimit (e.g. 10M, or "08:00,1M 19:00,off")
TPSLIMIT="${TPSLIMIT:-}"                  # rclone --tpslimit (transactions/sec); empty = default

DATE="$(date +%Y-%m-%d)"
LOCKDIR="$STATE_DIR/lock"
LAST_OK="$STATE_DIR/last-success"
SELF="$(basename "$0")"                  # our own script name, for lock-owner checks

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

# Filters shared by sync AND verify so both agree on what "should" be there.
# --links: symlinks are preserved as reversible .rclonelink files, NOT followed
# (avoids loops / ballooning), so nothing in the tree is silently skipped.
FILTERS=(
  --exclude ".DS_Store"
  --exclude "**/node_modules/**"
  --exclude "**/.venv/**"
  --exclude "**/venv/**"
  --exclude "**/__pycache__/**"
  --exclude "**/*.pyc"
  --exclude "**/.Trash/**"
  --exclude "*.icloud"          # never upload iCloud placeholder stubs
  # Transient/lock files: worthless to back up and a source of torn copies.
  # No "**/" prefix — like .DS_Store, these match the basename at ANY depth
  # (a "**/" pattern would need a directory level and miss root-level files).
  --exclude "*.sqlite-wal"
  --exclude "*.sqlite-shm"
  --exclude "*.sqlite-journal"
  --exclude "*-wal"
  --exclude "*-shm"
  --exclude '~$*'               # MS Office lock/temp (single-quoted: no $* expansion)
  --exclude ".~lock.*#"         # LibreOffice lock
  --links
)

# ---- helpers ---------------------------------------------------------------
logline() { echo "$(date '+%F %T') $*" >> "$LOG"; }
# Every user-facing notification is ALSO written to the log — a structural
# guarantee that nothing shown to the user is missing from the log. NOTIFY=0
# (used by the test suite) suppresses only the on-screen banner, never the log.
notify()  {
  logline "NOTIFY: $1"
  [ "${NOTIFY:-1}" = 1 ] && /usr/bin/osascript \
    -e "display notification \"$1\" with title \"Google Drive backup\"" 2>/dev/null
  return 0
}
fail()    { notify "FAILED: $1"; exit 1; }
skip()    { logline "SKIP: $1"; exit 0; }   # quiet, non-error; no banner (logged only)
# Per-source failure: report + mark the run failed, but DON'T exit — so one bad
# source (e.g. a permission-denied folder) can't starve the healthy ones.
source_fail() { notify "FAILED: $1"; had_error=1; }

# Resolve a SOURCES entry into globals `src` (local path) and `name` (dest
# subfolder). Absolute paths keep their basename; plain names sit under SRC_BASE.
resolve_src() {
  case "$1" in
    /*) src="$1";           name="$(basename "$1")" ;;
    *)  src="$SRC_BASE/$1";  name="$1" ;;
  esac
}

# Parse SOURCES into an array. The GUI writes newline-separated entries so paths
# with spaces work; the default/env form is space-separated names. (bash 3.2 —
# no mapfile.)
if [[ "$SOURCES" == *$'\n'* ]]; then
  SRC_LIST=()
  while IFS= read -r _line; do
    [ -n "$_line" ] && SRC_LIST+=("$_line")
  done <<< "$SOURCES"
else
  read -ra SRC_LIST <<< "$SOURCES"
fi

# ---- --status mode (no lock / no network) ----------------------------------
if [ "${1:-}" = "--status" ]; then
  ts="$(cat "$LAST_OK" 2>/dev/null || true)"
  # Guard against a missing/empty/corrupt timestamp: only do arithmetic on digits,
  # else `set -u` would abort trying to evaluate garbage in $(( )).
  case "$ts" in
    ''|*[!0-9]*)
      printf 'No successful backup recorded yet.\n' ;;
    *)
      now="$(date +%s)"; age=$(( (now - ts) / 60 ))
      printf 'Last successful backup: %s (%d min ago)\n' "$(date -r "$ts" '+%F %T')" "$age"
      [ "$age" -gt 1440 ] && printf 'WARNING: last success > 24h ago.\n' ;;
  esac
  exit 0
fi

ACTION=backup
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --verify)  ACTION=verify ;;
esac

# Refuse if no sources resolved (e.g. a config with blank/whitespace SOURCES).
# Also avoids a `set -u` crash when expanding an empty array in bash 3.2.
[ "${#SRC_LIST[@]}" -gt 0 ] || fail "SOURCES is empty — nothing to back up (check config)"

# Refuse two sources that map to the SAME dest subfolder. `name` is the basename,
# so /Volumes/A/Work and /Volumes/B/Work both become DEST/Work — the second sync
# would then see the first's files as deletions and gut them. Catch it up front.
# (newline delimiter is safe: SRC_LIST entries are newline-split, so a resolved
# `name` can never itself contain a newline.)
_seen_names=$'\n'
for entry in "${SRC_LIST[@]}"; do
  resolve_src "$entry"
  case "$_seen_names" in
    *$'\n'"$name"$'\n'*)
      fail "two sources map to the same backup folder '$name' (same basename) — rename or drop one; refusing to run" ;;
  esac
  _seen_names="$_seen_names$name"$'\n'
done

# ---- log rotation (keep one previous) --------------------------------------
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
  mv -f "$LOG" "$LOG.1"
fi

# ---- concurrency lock (mkdir is atomic; macOS has no flock) -----------------
# Self-healing against stale/duplicate runs: the lock blocks us ONLY when it is
# held by another genuinely-running copy of this engine. A lock left behind by a
# crash, a kill, or a pid the OS later recycled for an unrelated process is
# detected and reclaimed automatically — so a stale lock can never freeze every
# future backup, and no manual "rm -rf lock" is ever needed.
#
# lock_owner_alive PID → success only if PID is running AND is a copy of THIS
# script. `-ww` prevents ps from truncating the command (which could otherwise
# hide our long bundled path and cause a live backup to be misjudged as stale).
lock_owner_alive() {
  local p="$1"
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  ps -ww -p "$p" -o command= 2>/dev/null | grep -qF "$SELF"
}
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  lock_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if lock_owner_alive "$lock_pid"; then
    skip "another backup is already running (pid $lock_pid)"
  fi
  logline "reclaiming stale lock (pid=${lock_pid:-none} is not a live backup)"
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || skip "another run in progress"
fi
echo "$$" > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

# ---- preflight (shared by backup + verify) ---------------------------------
[ -x "$RCLONE" ] || fail "rclone not found/executable at $RCLONE"

if [ "$ALLOW_LOCAL_DEST" != 1 ]; then
  # Guard A: destination must be the gdrive: remote, never a local path.
  [[ "$DEST" == gdrive:* && "$TRASH" == gdrive:* ]] \
    || fail "DEST/TRASH are not gdrive: remotes — refusing to run"
  # Remote must actually be configured, else every run fails cryptically.
  "$RCLONE" listremotes 2>/dev/null | grep -qx "gdrive:" \
    || fail "rclone remote 'gdrive:' is not configured (run: rclone config)"
  # Offline? Skip quietly instead of crying wolf.
  /usr/bin/nc -z -w 5 www.googleapis.com 443 2>/dev/null \
    || skip "offline (googleapis.com:443 unreachable)"
fi

# ---- --verify mode: checksum-compare source against the backup -------------
if [ "$ACTION" = verify ]; then
  vfail=0
  for entry in "${SRC_LIST[@]}"; do
    resolve_src "$entry"
    logline "VERIFY $name"
    "$RCLONE" check "$src" "$DEST/$name" "${FILTERS[@]}" \
      --one-way --log-file "$LOG" --log-level NOTICE || vfail=1
  done
  if [ "$vfail" -ne 0 ]; then
    notify "VERIFY found differences — see $LOG"
    logline "VERIFY: differences found"
    exit 2
  fi
  logline "VERIFY: OK (source fully present & matching in backup)"
  exit 0
fi

# ---- backup ----------------------------------------------------------------
had_error=0
for entry in "${SRC_LIST[@]}"; do
  resolve_src "$entry"

  # iCloud control: refuse if the source contains un-downloaded iCloud
  # placeholders. Backing up 0-byte stubs is the #1 silent-failure mode. The
  # fix is to turn off "Optimise Mac Storage" or run `brctl download`.
  # Pre-sync "is everything actually downloaded?" check. When "Optimise Mac
  # Storage" evicts an iCloud file, macOS leaves a 0-byte `.name.icloud`
  # placeholder in its place — the real bytes are NOT on disk. Backing those up
  # would silently store empty stubs (the #1 silent data-loss mode), so if ANY
  # source contains placeholders we refuse that source and tell the user the
  # exact setting to turn off. (Count is capped for speed on huge trees.)
  icount="$(find "$src" -name "*.icloud" 2>/dev/null | head -2000 | grep -c . || true)"
  if [ "${icount:-0}" -gt 0 ]; then
    source_fail "$name: $icount file(s) are NOT downloaded — iCloud placeholders on disk. Turn OFF System Settings → Apple Account → iCloud → 'Optimise Mac Storage', or run: brctl download \"$src\". Refusing to back up 0-byte stubs (data-loss risk)."
    continue
  fi

  # Guard B: source must exist, be READABLE, and be non-empty. A missing/empty
  # source would move the ENTIRE Drive mirror into trash, so refuse. Crucially,
  # distinguish "permission denied" from "empty": on macOS a scheduled launchd
  # run without Full Disk Access reads a protected ~/Documents/~/Desktop as
  # empty, which looks identical to a truly-empty folder — so tell the user the
  # real fix instead of the misleading "empty".
  if [ ! -d "$src" ]; then
    source_fail "$name: source folder does not exist ($src) — refusing to sync."
    continue
  elif ! ls -A "$src" >/dev/null 2>&1; then
    source_fail "$name: cannot read $src (permission denied). Grant Full Disk Access to the backup: System Settings → Privacy & Security → Full Disk Access → add 'Drive Backup' and /bin/bash. Refusing to sync."
    continue
  elif [ -z "$(ls -A "$src" 2>/dev/null)" ]; then
    source_fail "$name is empty — refusing to sync (a truly empty source would gut the backup)."
    continue
  fi

  # Hard mass-deletion circuit breaker. `--max-delete N` alone deletes UP TO N
  # files before aborting (verified — it is not zero-delete-on-abort). So we
  # first COUNT the deletions a real sync would make, via a no-op --dry-run, and
  # refuse the real sync ENTIRELY if that exceeds MAX_DELETE. This guarantees
  # ZERO deletions when a source anomaly (corruption, wrong mount, mass move)
  # would otherwise gut the mirror. --max-delete stays on the real sync as a
  # second-line backstop against a change racing in after the dry-run.
  if [ "$DRY_RUN" != 1 ]; then
    plan="$("$RCLONE" sync "$src" "$DEST/$name" "${FILTERS[@]}" --fast-list --dry-run 2>&1)"
    dels="$(printf '%s\n' "$plan" | grep -c -i 'Skipped delete')"
    ups="$(printf '%s\n' "$plan"  | grep -c -iE 'Skipped (copy|update|move)')"
    # Surface the plan (adds/updates + deletes) so a big change is visible in the
    # log BEFORE it is applied — extra defence against a misconfig/mass change.
    logline "$name plan: ~$ups to upload/update, ~$dels to delete (limit $MAX_DELETE)"
    if [ "${dels:-0}" -gt "$MAX_DELETE" ]; then
      source_fail "$name: ABORTED — sync would delete $dels files (> MAX_DELETE=$MAX_DELETE); possible source loss. This source was left unchanged. Investigate before re-running."
      continue
    fi
  fi

  # Optional robustness knobs (see config): checksum compare, bandwidth + API-rate
  # limits. Empty/0 → omitted, so default behaviour is unchanged.
  xopts=()
  [ "$CHECKSUM" = 1 ]   && xopts+=(--checksum)
  [ -n "$BWLIMIT" ]     && xopts+=(--bwlimit "$BWLIMIT")
  [ -n "$TPSLIMIT" ]    && xopts+=(--tpslimit "$TPSLIMIT")

  opts=(
    --backup-dir "$TRASH/$DATE/$name"
    "${FILTERS[@]}"
    --max-delete "$MAX_DELETE"
    --fast-list --transfers 8 --checkers 16
    --contimeout 30s --timeout 300s --retries 3 --low-level-retries 10
    --log-file "$LOG" --log-level INFO
  )
  # Append xopts only when non-empty (bash 3.2 errors expanding an empty array
  # under `set -u`), matching how SRC_LIST is guarded above.
  [ "${#xopts[@]}" -gt 0 ] && opts+=("${xopts[@]}")
  [ "$DRY_RUN" = 1 ] && opts+=(--dry-run)

  "$RCLONE" sync "$src" "$DEST/$name" "${opts[@]}"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 9 ]; then
      source_fail "$name: ABORTED — >$MAX_DELETE deletions (backstop tripped); this source NOT fully modified. Investigate."
    else
      source_fail "$name sync failed (rc=$rc, see $LOG)"
    fi
    continue
  fi
done

# ---- retention: age out the trash (soft — goes to Drive's own trash) --------
# RETENTION of never/forever/off/0 (or empty) keeps everything: the trash is
# never purged, so all deleted/overwritten versions stay in Drive indefinitely.
if [ "$DRY_RUN" != 1 ]; then
  case "$RETENTION" in
    never|forever|off|0|"")
      logline "retention: keeping all trash (RETENTION=$RETENTION)" ;;
    *)
      "$RCLONE" delete "$TRASH" --min-age "$RETENTION" 2>>"$LOG" || true
      "$RCLONE" rmdirs "$TRASH" --leave-root 2>>"$LOG" || true ;;
  esac
  # Only record success when EVERY source synced — a partial run must not look
  # like a good backup to --status.
  [ "$had_error" -eq 0 ] && date +%s > "$LAST_OK"
fi

if [ "$had_error" -ne 0 ]; then
  logline "completed WITH ERRORS — one or more sources were skipped (see above)"
  exit 1
fi
logline "OK (dry_run=$DRY_RUN)"
