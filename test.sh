#!/bin/bash
# test-gdrive-backup.sh — end-to-end tests for icloud-gdrive-sync.sh
#
# Runs the REAL script against a throwaway sandbox: fake source dirs and a LOCAL
# directory standing in for the Google Drive remote (ALLOW_LOCAL_DEST=1). It
# never touches Google Drive, ~/Documents, ~/Desktop, iCloud, or the real logs.
#
# Usage: ./test.sh   (tests the engine in this repo, against a local sandbox)

# File-wide: check conditions are single-quoted strings expanded inside `eval "$2"`.
# shellcheck disable=SC2016
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/bin/icloud-gdrive-sync.sh"
SB="$(mktemp -d "${TMPDIR:-/tmp}/gdrive-test.XXXXXX")"
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [cond: $2]"; fi; }

# Sandbox paths — all inside $SB.
SRC="$SB/src"; REMOTE="$SB/remote"
export ALLOW_LOCAL_DEST=1
export NOTIFY=0                     # never post real macOS banners from the tests
export SRC_BASE="$SRC"
export DEST="$REMOTE/Mac-Backup"
export TRASH="$REMOTE/Mac-Backup-Trash"
export SOURCES="Documents Desktop"
export STATE_DIR="$SB/state"
export LOG="$SB/log/gdrive-sync.log"
export GDRIVE_BACKUP_CONFIG="$SB/no-such-config"   # isolate from any real config

run() { "$SCRIPT" "$@"; }   # inherits the exported env

seed() {
  rm -rf "$SRC"; mkdir -p "$SRC/Documents/Isiklik" "$SRC/Desktop"
  echo "hello"      > "$SRC/Documents/a.txt"
  echo "secret"     > "$SRC/Documents/Isiklik/b.txt"
  echo "desktopfile"> "$SRC/Desktop/c.txt"
  # cruft that MUST be excluded:
  mkdir -p "$SRC/Documents/proj/node_modules" "$SRC/Documents/proj/__pycache__"
  echo "junk" > "$SRC/Documents/proj/node_modules/x.js"
  echo "junk" > "$SRC/Documents/proj/__pycache__/x.pyc"
  echo "junk" > "$SRC/Documents/.DS_Store"
  echo "code" > "$SRC/Documents/proj/main.py"   # this one MUST be backed up
}

echo "Sandbox: $SB"
echo

echo "T1: fresh backup uploads everything (minus excludes)"
seed; run >/dev/null 2>&1
check "a.txt mirrored"            '[ -f "$DEST/Documents/a.txt" ]'
check "nested Isiklik/b.txt"      '[ -f "$DEST/Documents/Isiklik/b.txt" ]'
check "Desktop/c.txt mirrored"    '[ -f "$DEST/Desktop/c.txt" ]'
check "proj/main.py kept"         '[ -f "$DEST/Documents/proj/main.py" ]'
check "node_modules EXCLUDED"     '[ ! -e "$DEST/Documents/proj/node_modules" ]'
check "__pycache__ EXCLUDED"      '[ ! -e "$DEST/Documents/proj/__pycache__" ]'
check ".DS_Store EXCLUDED"        '[ ! -f "$DEST/Documents/.DS_Store" ]'
check "last-success recorded"     '[ -f "$STATE_DIR/last-success" ]'
echo

echo "T2: idempotent second run (no errors, files intact)"
run >/dev/null 2>&1; rc=$?
check "second run exit 0"         '[ "'$rc'" -eq 0 ]'
check "a.txt still present"       '[ -f "$DEST/Documents/a.txt" ]'
echo

echo "T3: SOURCE is never modified by the tool (the core safety invariant)"
srchash() { (cd "$SRC" && find . -type f | sort | xargs shasum 2>/dev/null | shasum | cut -d' ' -f1); }
rm "$SRC/Documents/a.txt"          # a USER deletion (not the tool)
before="$(srchash)"                # snapshot the exact state the tool will see
run >/dev/null 2>&1                # the tool runs
after="$(srchash)"
check "source byte-identical before/after sync" '[ "'"$before"'" = "'"$after"'" ]'
check "deleted file removed from DEST mirror"   '[ ! -f "$DEST/Documents/a.txt" ]'
check "deleted file preserved in TRASH"         'ls "$TRASH"/*/Documents/a.txt >/dev/null 2>&1'
check "OTHER source files untouched on disk"    '[ -f "$SRC/Documents/Isiklik/b.txt" ] && [ -f "$SRC/Desktop/c.txt" ]'
echo

echo "T4: modified file -> new content in DEST, old content in TRASH"
seed; run >/dev/null 2>&1                 # reset
echo "CHANGED" > "$SRC/Documents/a.txt"
run >/dev/null 2>&1
check "DEST has new content"       'grep -q CHANGED "$DEST/Documents/a.txt"'
check "TRASH has old content"      'grep -rq hello "$TRASH"/*/Documents/a.txt 2>/dev/null'
echo

echo "T5: Guard B — empty/missing source refuses (exit 1), DEST untouched"
seed; run >/dev/null 2>&1
rm -rf "$SRC/Documents"/* "$SRC/Documents"/.[!.]* 2>/dev/null   # empty it
run >/dev/null 2>&1; rc=$?
check "empty source -> exit 1"     '[ "'$rc'" -ne 0 ]'
check "DEST mirror NOT gutted"     '[ -f "$DEST/Documents/Isiklik/b.txt" ]'
echo

echo "T6: Guard A — non-remote DEST without test seam is refused"
( unset ALLOW_LOCAL_DEST; DEST="$REMOTE/Mac-Backup" TRASH="$REMOTE/Mac-Backup-Trash" \
    ALLOW_LOCAL_DEST=0 "$SCRIPT" >/dev/null 2>&1 ); rc=$?
check "local DEST refused (exit 1)" '[ "'$rc'" -ne 0 ]'
echo

echo "T7: mass-delete circuit breaker refuses with ZERO deletions when over limit"
seed
for i in $(seq 1 10); do echo "f$i" > "$SRC/Documents/file$i.txt"; done
run >/dev/null 2>&1                        # backup 10 files
rm "$SRC/Documents"/file*.txt              # delete all 10 from source
MAX_DELETE=2 run >/dev/null 2>&1; rc=$?
n_after="$(find "$DEST/Documents" -name 'file*.txt' | wc -l | tr -d ' ')"
check "abort exit != 0"                       '[ "'$rc'" -ne 0 ]'
check "ZERO deletions — all 10 files still in DEST" '[ "'"$n_after"'" = "10" ]'
echo

echo "T8: --dry-run changes nothing on DEST"
seed; run >/dev/null 2>&1
echo "NEWFILE" > "$SRC/Documents/dryrun-only.txt"
run --dry-run >/dev/null 2>&1
check "dry-run did NOT upload new file" '[ ! -f "$DEST/Documents/dryrun-only.txt" ]'
echo

echo "T9: concurrency lock self-heals (blocks real dupes, reclaims stale/foreign)"
seed; run >/dev/null 2>&1                         # establish a known-good DEST
# (a) lock held by a LIVE COPY OF THE ENGINE -> skip, do NOT run a second backup
STUB="$SB/icloud-gdrive-sync.sh"; printf '#!/bin/bash\nsleep 30\n' > "$STUB"; chmod +x "$STUB"
bash "$STUB" & stub_pid=$!
: > "$LOG"; mkdir -p "$STATE_DIR/lock"; echo "$stub_pid" > "$STATE_DIR/lock/pid"
echo "should-not-upload" > "$SRC/Documents/blocked.txt"
run >/dev/null 2>&1; rc=$?
check "live engine holds lock -> skip (exit 0)"        '[ "'$rc'" -eq 0 ]'
check "skip did NOT run a backup (file not uploaded)"  '[ ! -f "$DEST/Documents/blocked.txt" ]'
check "skip logged, no reclaim"                        'grep -q "already running" "$LOG" && ! grep -q "reclaiming" "$LOG"'
kill "$stub_pid" 2>/dev/null; wait "$stub_pid" 2>/dev/null; rm -rf "$STATE_DIR/lock"
# (b) lock held by a LIVE FOREIGN pid (pid reuse) -> reclaim + run
sleep 30 & foreign_pid=$!
: > "$LOG"; mkdir -p "$STATE_DIR/lock"; echo "$foreign_pid" > "$STATE_DIR/lock/pid"
run >/dev/null 2>&1; rc=$?
check "foreign live pid -> reclaimed, backup runs"     '[ "'$rc'" -eq 0 ] && [ -f "$DEST/Documents/blocked.txt" ]'
check "reclaim logged"                                 'grep -q "reclaiming stale lock" "$LOG"'
kill "$foreign_pid" 2>/dev/null; wait "$foreign_pid" 2>/dev/null; rm -rf "$STATE_DIR/lock"
# (c) stale lock with NO pid (crash between mkdir and pid write) -> reclaim
mkdir -p "$STATE_DIR/lock"; seed; run >/dev/null 2>&1; rc=$?
check "no-pid stale lock -> reclaimed, run succeeds"    '[ "'$rc'" -eq 0 ] && [ -f "$DEST/Documents/a.txt" ]'
# (d) dead pid -> reclaim
sleep 1 & dead=$!; kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null
mkdir -p "$STATE_DIR/lock"; echo "$dead" > "$STATE_DIR/lock/pid"
seed; run >/dev/null 2>&1; rc=$?
check "dead pid stale lock -> reclaimed, run succeeds"  '[ "'$rc'" -eq 0 ] && [ -f "$DEST/Documents/a.txt" ]'
echo

echo "T10: --status prints last-success"
seed; run >/dev/null 2>&1
out="$(run --status)"
check "--status reports success"  'echo "'"$out"'" | grep -q "Last successful backup"'
echo

echo "T11: Estonian/Unicode filenames round-trip (õ ä ö ü š ž)"
seed
mkdir -p "$SRC/Documents/Müük"
echo "arve" > "$SRC/Documents/Müük/Tähtis leping õäöü šž.txt"
run >/dev/null 2>&1
check "unicode dir+file mirrored" '[ -f "$DEST/Documents/Müük/Tähtis leping õäöü šž.txt" ]'
echo

echo "T12: iCloud placeholder (*.icloud) in source is refused, with actionable message"
seed
touch "$SRC/Documents/.BigFile.pdf.icloud"    # simulated iCloud stub
: > "$LOG"; run >/dev/null 2>&1; rc=$?
check "placeholder -> exit 1"      '[ "'$rc'" -ne 0 ]'
check "DEST not modified by stub run" '[ -f "$DEST/Documents/Isiklik/b.txt" ] || [ ! -d "$DEST/Documents" ]'
check "message names 'Optimise Mac Storage' + a count" 'grep -q "NOT downloaded" "$LOG" && grep -q "Optimise Mac Storage" "$LOG"'
echo

echo "T13: symlink preserved as a link (not dereferenced/copied)"
# local->local: --links round-trips as a real symlink; against Google Drive
# (no symlink support) it is stored as a reversible .rclonelink file. Either
# way the link is preserved and its target is NOT followed & copied.
seed
ln -s "/etc/hosts" "$SRC/Documents/link-to-hosts"
run >/dev/null 2>&1
check "symlink preserved as a link, target not copied" '[ -L "$DEST/Documents/link-to-hosts" ]'
echo

echo "T14: --verify passes when matching, flags a missing file"
seed; run >/dev/null 2>&1
out="$(run --verify 2>&1)"; rc=$?
check "verify clean -> exit 0"     '[ "'$rc'" -eq 0 ]'
# Now remove a file directly from the BACKUP (simulate corruption/loss on Drive)
rm -f "$DEST/Documents/Isiklik/b.txt"
run --verify >/dev/null 2>&1; rc=$?
check "verify detects missing backup file -> exit 2" '[ "'$rc'" -eq 2 ]'
echo

echo "T15: GUI config file overrides env (SOURCES + MAX_DELETE)"
seed
CFG="$SB/gui-config"
mkdir -p "$SRC/ConfigOnly"
for i in $(seq 1 11); do echo "c$i" > "$SRC/ConfigOnly/f$i.txt"; done
printf 'SOURCES="ConfigOnly"\nMAX_DELETE=2\n' > "$CFG"
GDRIVE_BACKUP_CONFIG="$CFG" run >/dev/null 2>&1
# ConfigOnly is only in the config's SOURCES, never in env SOURCES — its presence
# in DEST proves the config file overrode the environment.
check "config SOURCES honored/overrode env (ConfigOnly backed up)" '[ -f "$DEST/ConfigOnly/f1.txt" ]'
for i in $(seq 1 10); do rm "$SRC/ConfigOnly/f$i.txt"; done   # 10 deletions, keep f11 (non-empty)
GDRIVE_BACKUP_CONFIG="$CFG" run >/dev/null 2>&1; rc=$?
check "config MAX_DELETE=2 honored (mass-delete aborted)" '[ "'$rc'" -ne 0 ]'
n="$(find "$DEST/ConfigOnly" -name 'f*.txt' | wc -l | tr -d ' ')"
check "abort left all 11 files in DEST (zero deletions)" '[ "'"$n"'" = "11" ]'
echo

echo "T16: absolute-path source is backed up under its basename"
seed
ABSDIR="$SB/AbsFolder"; mkdir -p "$ABSDIR"; echo "abs" > "$ABSDIR/x.txt"
SOURCES="$ABSDIR" run >/dev/null 2>&1
check "absolute source mirrored under basename" '[ -f "$DEST/AbsFolder/x.txt" ]'
check "source (outside SRC_BASE) untouched"     '[ -f "$ABSDIR/x.txt" ]'
echo

echo "T17: source path containing a space (newline-form SOURCES) works"
seed
SPDIR="$SB/Space Folder"; mkdir -p "$SPDIR"; echo "x" > "$SPDIR/f.txt"
CFG2="$SB/cfg-space"
printf 'SOURCES="%s\n"\n' "$SPDIR" > "$CFG2"     # GUI writes entries newline-separated
GDRIVE_BACKUP_CONFIG="$CFG2" run >/dev/null 2>&1
check "space-in-path source mirrored under basename" '[ -f "$DEST/Space Folder/f.txt" ]'
echo

echo "T18: blank/whitespace SOURCES refuses (no crash, no silent no-op)"
seed
CFG3="$SB/cfg-empty"
printf 'SOURCES="\n"\n' > "$CFG3"          # value is only a newline -> zero entries
GDRIVE_BACKUP_CONFIG="$CFG3" run >/dev/null 2>&1; rc=$?
check "empty SOURCES -> exit 1" '[ "'$rc'" -ne 0 ]'
echo

echo "T19: RETENTION=never keeps all trash (never purges)"
seed
CFG4="$SB/cfg-never"; printf 'RETENTION="never"\n' > "$CFG4"
GDRIVE_BACKUP_CONFIG="$CFG4" run >/dev/null 2>&1
rm "$SRC/Documents/a.txt"                    # create a trash entry
GDRIVE_BACKUP_CONFIG="$CFG4" run >/dev/null 2>&1; rc=$?
check "never-run succeeds (exit 0)"        '[ "'$rc'" -eq 0 ]'
check "log records keeping-all-trash"      'grep -q "keeping all trash" "$LOG"'
check "trashed file preserved"             'ls "$TRASH"/*/Documents/a.txt >/dev/null 2>&1'
echo

echo "T20: symbols / long names / emoji round-trip, stay churn-free, verify clean"
seed
mkdir -p "$SRC/Documents/Müük õäöü šž"
echo v > "$SRC/Documents/Müük õäöü šž/leping (õäöü) šž.txt"   # estonian + parens + space
echo v > "$SRC/Documents/A & B, C.txt"                        # ampersand, comma
echo v > "$SRC/Documents/file #1 (draft) 100%.txt"           # hash, parens, percent
echo v > "$SRC/Documents/it's a \"quoted\" name.txt"         # single + double quotes
echo v > "$SRC/Documents/café — naïve — Zürich.txt"          # accents + em-dash
echo v > "$SRC/Documents/emoji 🌍✅.txt"                       # emoji
LONG="$(printf 'a%.0s' $(seq 1 200))"                         # 200-char component name
mkdir -p "$SRC/Documents/$LONG"; echo v > "$SRC/Documents/$LONG/$LONG.txt"
run >/dev/null 2>&1
check "unicode+space+parens dir/file mirrored" '[ -f "$DEST/Documents/Müük õäöü šž/leping (õäöü) šž.txt" ]'
check "ampersand/comma name mirrored"          '[ -f "$DEST/Documents/A & B, C.txt" ]'
check "hash/percent/parens name mirrored"      '[ -f "$DEST/Documents/file #1 (draft) 100%.txt" ]'
check "accent/em-dash name mirrored"           '[ -f "$DEST/Documents/café — naïve — Zürich.txt" ]'
check "emoji name mirrored"                    '[ -f "$DEST/Documents/emoji 🌍✅.txt" ]'
check "200-char dir+file mirrored"             '[ -f "$DEST/Documents/'"$LONG"'/'"$LONG"'.txt" ]'
# quoted-name file (single quote breaks a path literal in check) — proven via verify below
: > "$LOG"                                       # isolate the SECOND run's activity in the log
run >/dev/null 2>&1
check "second run: zero uploads (idempotent)"  '! grep -q "Copied" "$LOG"'
check "second run: zero deletions (idempotent)" '! grep -Eqi "Deleted|Skipped delete" "$LOG"'
run --verify >/dev/null 2>&1; rc=$?
check "verify clean on nasty names (exit 0)"    '[ "'$rc'" -eq 0 ]'
echo

echo "T21: two sources with the same basename are refused (dest-folder collision)"
seed
mkdir -p "$SB/A/Work" "$SB/B/Work"; echo x > "$SB/A/Work/a.txt"; echo y > "$SB/B/Work/b.txt"
CFG5="$SB/cfg-collide"
printf 'SOURCES="%s\n%s\n"\n' "$SB/A/Work" "$SB/B/Work" > "$CFG5"   # both -> DEST/Work
GDRIVE_BACKUP_CONFIG="$CFG5" run >/dev/null 2>&1; rc=$?
check "same-basename sources -> exit 1"          '[ "'$rc'" -ne 0 ]'
check "collision refused before any upload"      '[ ! -d "$DEST/Work" ]'
echo

echo "T22: every user-facing notification is written to the log (NOTIFY guard)"
# (a) a failure notification is logged even with the on-screen banner suppressed
seed; run >/dev/null 2>&1
rm -rf "$SRC/Documents"/* "$SRC/Documents"/.[!.]* 2>/dev/null   # empty -> fail() -> notify
: > "$LOG"; run >/dev/null 2>&1
check "failure notification logged (NOTIFY: FAILED …)" 'grep -q "NOTIFY: FAILED" "$LOG"'
# (b) a verify-differences notification is logged
seed; run >/dev/null 2>&1
rm -f "$DEST/Documents/Isiklik/b.txt"           # backup now differs from source
: > "$LOG"; run --verify >/dev/null 2>&1
check "verify-difference notification logged"    'grep -q "NOTIFY: VERIFY found differences" "$LOG"'
echo

echo "T23: transient/lock files are excluded (never backed up)"
seed
printf 'x' > "$SRC/Documents/data.sqlite-wal"
printf 'x' > "$SRC/Documents/data.sqlite-shm"
printf 'x' > "$SRC/Documents/~\$report.docx"        # MS Office lock/temp
printf 'x' > "$SRC/Documents/.~lock.sheet.ods#"     # LibreOffice lock
printf 'keepme' > "$SRC/Documents/real.txt"
run >/dev/null 2>&1
check "sqlite-wal excluded"           '[ ! -f "$DEST/Documents/data.sqlite-wal" ]'
check "sqlite-shm excluded"           '[ ! -f "$DEST/Documents/data.sqlite-shm" ]'
check "MS Office ~\$ lock excluded"   '[ ! -f "$DEST/Documents/~\$report.docx" ]'
check "LibreOffice lock excluded"     '[ ! -f "$DEST/Documents/.~lock.sheet.ods#" ]'
check "real file still backed up"     '[ -f "$DEST/Documents/real.txt" ]'
echo

echo "T24: robustness knobs (checksum/bwlimit/tpslimit) work; sync plan is logged"
seed; : > "$LOG"
CHECKSUM=1 BWLIMIT=10M TPSLIMIT=10 run >/dev/null 2>&1; rc=$?
check "checksum+bwlimit+tpslimit run succeeds"   '[ "'$rc'" -eq 0 ] && [ -f "$DEST/Documents/a.txt" ]'
check "sync plan logged (upload/delete counts)"  'grep -q "plan: ~.* to upload/update, ~.* to delete" "$LOG"'
echo

echo "T25: per-source isolation — one bad source does not block the healthy ones"
seed; run >/dev/null 2>&1                                   # good baseline in DEST
rm -rf "$SRC/Documents"/* "$SRC/Documents"/.[!.]* 2>/dev/null   # empty Documents only
echo "fresh" > "$SRC/Desktop/newdesk.txt"                  # a new Desktop file
rm -f "$STATE_DIR/last-success"; : > "$LOG"
run >/dev/null 2>&1; rc=$?
check "run exits nonzero (a source failed)"        '[ "'$rc'" -ne 0 ]'
check "healthy Desktop STILL backed up"            '[ -f "$DEST/Desktop/newdesk.txt" ]'
check "empty Documents mirror NOT gutted"          '[ -f "$DEST/Documents/Isiklik/b.txt" ]'
check "empty source gets its own clear message"    'grep -q "Documents is empty" "$LOG"'
check "no last-success recorded on partial run"    '[ ! -f "$STATE_DIR/last-success" ]'
echo

echo "T26: unreadable source -> permission error (Full Disk Access), not 'empty'"
NOPERM="$SB/NoPerm"; rm -rf "$NOPERM"; mkdir -p "$NOPERM"; echo x > "$NOPERM/f.txt"
CFG6="$SB/cfg-noperm"; printf 'SOURCES="%s\n"\n' "$NOPERM" > "$CFG6"
GDRIVE_BACKUP_CONFIG="$CFG6" run >/dev/null 2>&1            # back it up while readable
chmod 000 "$NOPERM"
: > "$LOG"; GDRIVE_BACKUP_CONFIG="$CFG6" run >/dev/null 2>&1; rc=$?
chmod 755 "$NOPERM"                                        # restore so cleanup works
check "unreadable source -> exit nonzero"          '[ "'$rc'" -ne 0 ]'
check "error names Full Disk Access (not 'empty')" 'grep -q "Full Disk Access" "$LOG" && ! grep -q "NoPerm is empty" "$LOG"'
check "unreadable source mirror NOT gutted"        '[ -f "$DEST/NoPerm/f.txt" ]'
echo

echo "T27: --status is robust against a missing/empty/corrupt timestamp"
mkdir -p "$STATE_DIR"
printf 'not-a-number' > "$STATE_DIR/last-success"
out="$(run --status 2>&1)"; rc=$?
check "corrupt timestamp -> clean message, no bash error" '[ "'$rc'" -eq 0 ] && echo "'"$out"'" | grep -q "No successful backup" && ! echo "'"$out"'" | grep -qi "unbound\|error"'
: > "$STATE_DIR/last-success"
out="$(run --status 2>&1)"
check "empty timestamp -> clean message"                 'echo "'"$out"'" | grep -q "No successful backup"'
echo

echo "=================================================="
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
