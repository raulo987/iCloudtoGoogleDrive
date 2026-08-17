#!/bin/bash
# rclone-setup.command — double-clickable / opened by the GUI in Terminal.
# One-time Google Drive OAuth setup for the backup (delegated here so the GUI
# never touches Google credentials or tokens).
#
# Bilingual (Estonian / English): follows GUI_LANG from the generated config if
# present, otherwise the macOS system language. Every user-facing line goes
# through msg "<estonian>" "<english>".

RCLONE=/opt/homebrew/bin/rclone
CONFIG="$HOME/.config/gdrive-backup/config"

# ---- language selection ----------------------------------------------------
LANG_PREF=""
if [ -f "$CONFIG" ]; then
  # Read only GUI_LANG in a subshell so the rest of the config can't leak in.
  LANG_PREF="$( . "$CONFIG" 2>/dev/null; printf '%s' "${GUI_LANG:-}" )"
fi
if [ -z "$LANG_PREF" ]; then                         # fall back to the system locale
  case "$(defaults read -g AppleLocale 2>/dev/null)" in
    et*|*_EE) LANG_PREF=et ;;
    *)        LANG_PREF=en ;;
  esac
fi
msg() { if [ "$LANG_PREF" = et ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi; }
ask() { if [ "$LANG_PREF" = et ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

echo "=================================================="
msg "   Google Drive seadistus backupi jaoks (rclone)" \
    "   Google Drive setup for the backup (rclone)"
echo "=================================================="
echo

if [ ! -x "$RCLONE" ]; then
  msg "VIGA: rclone puudub ($RCLONE). Paigalda: brew install rclone" \
      "ERROR: rclone missing ($RCLONE). Install it: brew install rclone"
  ask "Vajuta Enter, et sulgeda. " "Press Enter to close. "; read -r _; exit 1
fi

# ---- your own Google OAuth client_id (recommended) -------------------------
# rclone's shared client_id is being retired during 2026 and is heavily
# rate-limited. Using your own free client_id avoids both. Guide:
#   https://rclone.org/drive/#making-your-own-client-id
CID=""; CSECRET=""
ask "Kasuta oma Google client_id't? (SOOVITATAV — jagatud ID aegub 2026) [y/N] " \
    "Use your own Google client_id? (RECOMMENDED — the shared one retires in 2026) [y/N] "
read -r useown
case "$useown" in
  y|Y)
    msg "Loo see tasuta: https://rclone.org/drive/#making-your-own-client-id" \
        "Create one (free): https://rclone.org/drive/#making-your-own-client-id"
    ask "client_id: " "client_id: ";         read -r CID
    ask "client_secret: " "client_secret: "; read -r CSECRET
    ;;
  *) msg "Kasutan jagatud client_id't (võib 2026 lakata töötamast)." \
         "Using the shared client_id (may stop working in 2026)." ;;
esac

if "$RCLONE" listremotes 2>/dev/null | grep -qx "gdrive:"; then
  msg "Remote 'gdrive:' on juba olemas." "Remote 'gdrive:' already exists."
  ask "Kas ühendada uuesti (uuenda OAuth-luba)? [y/N] " \
      "Reconnect (refresh the OAuth grant)? [y/N] "
  read -r ans
  case "$ans" in
    y|Y)
      if [ -n "$CID" ]; then
        "$RCLONE" config update gdrive client_id "$CID" client_secret "$CSECRET" >/dev/null 2>&1
      fi
      "$RCLONE" config reconnect gdrive: ;;
    *)   msg "Muudatusteta." "No changes." ;;
  esac
else
  msg "Loon uue remote'i nimega 'gdrive'. Brauser avaneb Google'i sisselogimiseks." \
      "Creating a new remote named 'gdrive'. A browser opens to sign in to Google."
  echo
  create_args=(gdrive drive)
  [ -n "$CID" ]     && create_args+=(client_id "$CID")
  [ -n "$CSECRET" ] && create_args+=(client_secret "$CSECRET")
  "$RCLONE" config create "${create_args[@]}"
fi

echo
msg "Kontroll:" "Check:"
if ! "$RCLONE" listremotes 2>/dev/null | grep -qx "gdrive:"; then
  msg "  ✗ 'gdrive:' pole veel seadistatud — proovi uuesti." \
      "  ✗ 'gdrive:' is not configured yet — try again."
else
  msg "  ✓ remote 'gdrive:' kirje olemas." "  ✓ remote 'gdrive:' entry exists."
  ask "  … kontrollin päris ühendust (OAuth kehtiv?)… " \
      "  … checking the live connection (OAuth valid?)… "
  if "$RCLONE" lsd gdrive: --max-depth 1 >/dev/null 2>&1; then
    msg "OK — ühendus töötab." "OK — the connection works."
  else
    msg "EI TÖÖTA." "NOT WORKING."
    msg "    Remote on olemas, aga ligipääs ebaõnnestus (OAuth pooleli/aegunud)." \
        "    The remote exists but access failed (OAuth incomplete/expired)."
    msg "    Käivita see aken uuesti ja vali 'reconnect'." \
        "    Run this window again and choose 'reconnect'."
  fi
fi
echo
msg "Valmis. Võid selle akna sulgeda." "Done. You can close this window."
