#\!/bin/bash
# Transmission completion script - organizes media using hard links

# Transmission environment variables:
# TR_APP_VERSION, TR_TIME_LOCALTIME, TR_TORRENT_DIR, TR_TORRENT_HASH, TR_TORRENT_ID, TR_TORRENT_NAME

SCRIPT_DIR="$(dirname "$0")"
ORGANIZER="$SCRIPT_DIR/media_organizer.py"
LOG_FILE="$HOME/mediaserver-enhanced/logs/transmission_complete.log"

# Log the completion
echo "[$(date)] Torrent completed: $TR_TORRENT_NAME" >> "$LOG_FILE"
echo "[$(date)] Directory: $TR_TORRENT_DIR" >> "$LOG_FILE"

# Run the organizer
python3 "$ORGANIZER" "$TR_TORRENT_DIR" >> "$LOG_FILE" 2>&1

# Log completion
echo "[$(date)] Organization complete for: $TR_TORRENT_NAME" >> "$LOG_FILE"
echo "---" >> "$LOG_FILE"
