# Hardlink Media Organization System

## Overview
This system automatically organizes downloaded media using hard links.

## Benefits
- Keep files in Transmission download folder (maintains seeding)
- Organized libraries for Jellyfin  
- Zero extra disk space used
- Automatic organization on download completion

## Usage

### Automatic (after torrent completion)
Files are automatically organized when torrents complete.

### Manual organization
Run: ./scripts/organize_manual.sh

### Check results
- Movies: storage/media/movies/
- TV Shows: storage/media/tv/

## Verification
Both files should have same inode:
stat storage/downloads/complete/file.mp4
stat storage/media/movies/Movie/file.mp4

## Jellyfin Setup
Add libraries pointing to:
- Movies: /home/matthewhans/mediaserver-enhanced/storage/media/movies  
- TV: /home/matthewhans/mediaserver-enhanced/storage/media/tv

## Logs
Check logs/ directory for organization activity.
