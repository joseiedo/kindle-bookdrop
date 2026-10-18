#!/bin/sh
# Copy the plugin onto a USB-mounted Kindle.
set -e
cd "$(dirname "$0")"
KINDLE="${KINDLE:-/Volumes/Kindle}"
DEST="$KINDLE/koreader/plugins/bookdrop.koplugin"
[ -d "$KINDLE/koreader/plugins" ] || { echo "No KOReader found at $KINDLE (is the Kindle mounted?)"; exit 1; }
rsync -rt --delete --exclude '.DS_Store' bookdrop.koplugin/ "$DEST/"
echo "Installed to $DEST. Eject the Kindle and restart KOReader."
