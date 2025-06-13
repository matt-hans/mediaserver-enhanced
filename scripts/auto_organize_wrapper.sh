#\!/bin/bash
# Auto-organize wrapper for Transmission
# This script is called when a torrent completes

# Log function
log() {
    echo "[2025-06-13 02:54:25] " >> /home/matthewhans/mediaserver-enhanced/logs/auto_organize.log
}

log "Auto-organize triggered for: "

# Call the media organizer
cd /home/matthewhans/mediaserver-enhanced
python3 scripts/media_organizer.py >> logs/auto_organize.log 2>&1

log "Auto-organize completed for: "
