#\!/bin/bash
# Usage: ./delete_movie.sh "search_term"
# This script removes both the original file and hardlinks

if [ -z "$1" ]; then
    echo "Usage: $0 'search_term'"
    echo "Example: $0 '28 Days'"
    exit 1
fi

SEARCH_TERM="$1"
DOWNLOADS_DIR="/mnt/storage/downloads/complete"
MEDIA_DIR="/mnt/storage/media"

echo "Searching for files containing: $SEARCH_TERM"

# Find and delete from downloads first
echo "\nRemoving from downloads directory:"
find "$DOWNLOADS_DIR" -name "*$SEARCH_TERM*" -type f -exec rm -v {} \;
find "$DOWNLOADS_DIR" -name "*$SEARCH_TERM*" -type d -empty -exec rmdir -v {} \; 2>/dev/null

# Find and delete from media 
echo "\nRemoving from media directory:"
find "$MEDIA_DIR" -name "*$SEARCH_TERM*" -type f -exec rm -v {} \;
find "$MEDIA_DIR" -name "*$SEARCH_TERM*" -type d -empty -exec rmdir -v {} \; 2>/dev/null

echo "\nTriggering Jellyfin library refresh..."
curl -X POST 'http://localhost:8096/Library/Refresh'

echo "\nDeletion complete\!"
