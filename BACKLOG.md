# Backlog — future work

Ideas and known trade-offs, not bugs. The shipped tool is safe and tested; these
would make it more robust or nicer. Roughly ordered by value ÷ effort.

## Reliability (opt-in features, deliberately not bundled yet)

- **Encryption at rest (`rclone crypt`).** Zero-knowledge client-side encryption so
  Google Drive never sees plaintext. Store the passphrase in the macOS Keychain.
  Deferred because it changes the on-Drive format (needs a one-time re-upload) and
  a lost passphrase means permanent data loss — must be explicit opt-in with loud
  warnings. Effort: **M**.
- **Second, immutable copy (restic / Borg, append-only).** Defends against the
  ransomware / "attacker with Drive creds empties the trash" case that the trash +
  `MAX_DELETE` guard don't fully cover. Separate backend. Effort: **M–L**.
- **Point-in-time source consistency (APFS local snapshot).** `tmutil localsnapshot`
  and sync from the mounted snapshot, so a live database / Photos library is
  captured consistently instead of mid-write. Effort: **M**.
- **Sampled restore test.** A periodic job that restores a small random subset to a
  scratch dir and diffs it against the source — proves backups actually come back,
  not just that checksums match. Effort: **M**.

## Polish / smaller

- **Coalesce failure notifications.** With per-source reporting, N failing folders
  post N banners. Post a single summary banner per run instead (still log each).
  Effort: **S**.
- **Verify shouldn't starve backups.** The weekly integrity-verify shares the
  backup lock (safe — no concurrent rclone on the same remote), so a very long
  verify can make an hourly backup skip until it finishes. Options: run verify
  lock-free (it is read-only), or use a separate lock. Effort: **S–M**.
- **Show verify-schedule state in the menu.** The menu shows the backup schedule
  state but not whether the weekly integrity check is on. Effort: **S**.
- **Expose `TPSLIMIT` and the verify interval in Settings** (currently config-file
  / env only). Effort: **S**.
- **Regenerate the Settings screenshot** for the README/landing page to show the
  newer options (checksum / bandwidth / weekly integrity check). Effort: **S**.

## Notes

- macOS metadata (xattrs, Finder tags, resource forks, permissions) is not
  preserved to Drive — documented as a known limitation; an optional
  `ditto`/`tar` archive mode could preserve it for folders that need it. Effort: **M**.
