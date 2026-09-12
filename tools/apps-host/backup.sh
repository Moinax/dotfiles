#!/usr/bin/env bash
# Keep plaintext staging private and remove it on failure as well as success.
set -euo pipefail
umask 077
exec 9>/var/lib/apps-backup/backup.lock
flock -n 9 || exit 0
stage=$(mktemp -d /var/lib/apps-backup/stage.XXXXXX)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/data" "$stage/config" "$stage/releases"
cp -a /etc/personal-apps/. "$stage/config/"
if [[ -d /etc/apps-proxy ]]; then
    cp -a /etc/apps-proxy "$stage/config/apps-proxy"
fi
for app in finance daylight; do
    [[ -f /var/lib/$app/.migrated ]] || { echo "$app has not been migrated" >&2; exit 1; }
    mkdir "$stage/data/$app"
    if [[ $app == finance ]]; then
        sqlite3 /var/lib/finance/finance.sqlite ".backup '$stage/data/finance/finance.sqlite'"
        cp /var/lib/finance/enablebanking.pem "$stage/data/finance/"
    else
        cp /var/lib/daylight/master.key /var/lib/daylight/daylight.enc "$stage/data/daylight/"
    fi
    cp "/opt/personal-apps/$app/current/source.tar.gz" "$stage/releases/$app.tar.gz"
    readlink "/opt/personal-apps/$app/current" > "$stage/releases/$app.txt"
done
archive="/var/lib/apps-backup/$(date -u +%Y%m%dT%H%M%SZ).tar.gz.age"
tar -czf - -C "$stage" . | age -R /etc/personal-apps/backup-recipient.pub -o "$archive.partial"
mv "$archive.partial" "$archive"
find /var/lib/apps-backup -maxdepth 1 -name '*.tar.gz.age' -mtime +14 -delete
printf 'Backup ready: %s\n' "$(basename "$archive")"
