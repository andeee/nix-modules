#!/usr/bin/env sh
URL=$1
if command -v teams-for-linux; then
  case "$URL" in
    *teams.microsoft.com*)
      NEW_URL=$(echo "$URL" | sed -E "s/https?:\/\/teams.microsoft.com/msteams:/g")
      echo "opening teams-for-linux using ${NEW_URL}"
      teams-for-linux --url "${NEW_URL}"
    ;;
    *) echo default
      qutebrowser --untrusted-args "$URL"
    ;;
  esac
else
  qutebrowser --untrusted-args "$URL"
fi
