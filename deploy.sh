#!/bin/sh
# Copy the plugin onto the Kindle.
#   ./deploy.sh                    over USB (Kindle mounted, KOReader closed)
#   ./deploy.sh 192.168.1.23       over Wi-Fi, via KOReader's SSH server (Network → SSH server)
set -e
cd "$(dirname "$0")"

if [ -n "$1" ]; then
    HOST="$1"
    PORT="${SSH_PORT:-2222}"
    KEY="${SSH_KEY:-$HOME/.ssh/kindle_ed25519}" # its .pub goes in koreader/settings/SSH/authorized_keys
    DEST=/mnt/us/koreader/plugins/bookdrop.koplugin
    # The Kindle has no rsync; stream a tarball and swap the folder in place
    COPYFILE_DISABLE=1 tar -C bookdrop.koplugin --exclude '.DS_Store' --exclude '._*' -cf - . |
        ssh -p "$PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new ${KEY:+-i "$KEY"} "root@$HOST" \
            "rm -rf $DEST.new && mkdir -p $DEST.new && tar -xf - -C $DEST.new && rm -rf $DEST && mv $DEST.new $DEST"
    echo "Installed to $HOST:$DEST. Restart KOReader to load it (Exit → Restart KOReader)."
    exit 0
fi

KINDLE="${KINDLE:-/Volumes/Kindle}"
DEST="$KINDLE/koreader/plugins/bookdrop.koplugin"
[ -d "$KINDLE/koreader/plugins" ] || { echo "No KOReader found at $KINDLE (is the Kindle mounted?)"; exit 1; }
rsync -rt --delete --exclude '.DS_Store' --exclude '._*' bookdrop.koplugin/ "$DEST/"
# macOS leaves AppleDouble "._" files on the Kindle's FAT filesystem
dot_clean -m "$DEST" 2>/dev/null || find "$DEST" -name '._*' -delete
echo "Installed to $DEST. Eject the Kindle and restart KOReader."
