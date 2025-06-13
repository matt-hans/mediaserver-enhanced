#\!/bin/bash
# Manual organization script for existing downloads

SCRIPT_DIR="$(dirname "$0")"
ORGANIZER="$SCRIPT_DIR/media_organizer.py"

echo "Manual Media Organization Tool"
echo "============================="
echo "This will organize all files in downloads/complete using hard links"
echo "Files will remain in download location for seeding"
echo ""

read -p "Proceed? (y/N): " confirm
if [[ $confirm \!= [yY] ]]; then
    echo "Cancelled"
    exit 0
fi

echo ""
echo "Organizing media files..."
python3 "$ORGANIZER"

echo ""
echo "Organization complete\!"
echo "Check results in:"
echo "- Movies: ~/mediaserver-enhanced/storage/media/movies/"
echo "- TV Shows: ~/mediaserver-enhanced/storage/media/tv/"
