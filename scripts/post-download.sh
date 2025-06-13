#!/bin/bash
# Post-Download Processing Script
# ===============================
# Called by Transmission when a download completes
# Organizes media files and notifies Jellyfin for library updates

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/config/post-download.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Validate Transmission environment variables
validate_env() {
    local required_vars=("TR_TORRENT_DIR" "TR_TORRENT_NAME" "TR_TORRENT_ID")
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            error_exit "Required environment variable $var is not set"
        fi
    done
    
    log "Torrent processing started"
    log "Torrent Name: $TR_TORRENT_NAME"
    log "Torrent ID: $TR_TORRENT_ID"
    log "Download Directory: $TR_TORRENT_DIR"
    log "Torrent Hash: ${TR_TORRENT_HASH:-N/A}"
}

# Determine media type and destination
determine_media_type() {
    local torrent_name="$1"
    local source_path="$2"
    
    log "Analyzing media type for: $torrent_name"
    
    # TV Show patterns (Season/Episode indicators)
    if [[ "$torrent_name" =~ (S[0-9]{1,2}E[0-9]{1,2}|[0-9]{1,2}x[0-9]{1,2}|Season|Episode) ]]; then
        echo "tv"
        return
    fi
    
    # Check file extensions in the downloaded content
    local video_files
    video_files=$(find "$source_path" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" \) 2>/dev/null | wc -l)
    
    local audio_files
    audio_files=$(find "$source_path" -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.wav" -o -iname "*.aac" -o -iname "*.ogg" -o -iname "*.wma" \) 2>/dev/null | wc -l)
    
    local book_files
    book_files=$(find "$source_path" -type f \( -iname "*.pdf" -o -iname "*.epub" -o -iname "*.mobi" -o -iname "*.azw*" -o -iname "*.txt" \) 2>/dev/null | wc -l)
    
    # Determine type based on file content
    if [ "$video_files" -gt 0 ]; then
        if [ "$video_files" -eq 1 ] && [[ ! "$torrent_name" =~ (S[0-9]{1,2}|Season) ]]; then
            echo "movies"
        else
            echo "tv"
        fi
    elif [ "$audio_files" -gt 0 ]; then
        echo "music"
    elif [ "$book_files" -gt 0 ]; then
        echo "books"
    else
        echo "misc"
    fi
}

# Create hardlinks to preserve seeding
create_hardlinks() {
    local source_dir="$1"
    local dest_dir="$2"
    local torrent_name="$3"
    
    log "Creating hardlinks from $source_dir to $dest_dir"
    
    # Ensure destination directory exists
    mkdir -p "$dest_dir"
    
    # Handle single file vs directory
    if [ -f "$source_dir/$torrent_name" ]; then
        # Single file
        ln "$source_dir/$torrent_name" "$dest_dir/$torrent_name" 2>/dev/null || {
            log "Hardlink failed, copying file instead"
            cp "$source_dir/$torrent_name" "$dest_dir/$torrent_name"
        }
    elif [ -d "$source_dir/$torrent_name" ]; then
        # Directory - create hardlinks for all files
        find "$source_dir/$torrent_name" -type f | while read -r file; do
            local rel_path="${file#$source_dir/$torrent_name/}"
            local dest_file="$dest_dir/$torrent_name/$rel_path"
            local dest_subdir
            dest_subdir=$(dirname "$dest_file")
            
            mkdir -p "$dest_subdir"
            ln "$file" "$dest_file" 2>/dev/null || {
                log "Hardlink failed for $file, copying instead"
                cp "$file" "$dest_file"
            }
        done
    else
        error_exit "Source not found: $source_dir/$torrent_name"
    fi
    
    log "File organization completed"
}

# Set proper permissions
set_permissions() {
    local dest_path="$1"
    
    log "Setting permissions for: $dest_path"
    
    # Use environment variables if available, otherwise defaults
    local puid="${PUID:-1000}"
    local pgid="${PGID:-1000}"
    
    # Set ownership and permissions
    chown -R "$puid:$pgid" "$dest_path" 2>/dev/null || log "Warning: Could not change ownership"
    chmod -R 755 "$dest_path" 2>/dev/null || log "Warning: Could not change permissions"
    
    # Make video files readable
    find "$dest_path" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" \) -exec chmod 644 {} \; 2>/dev/null || true
}

# Organize TV shows into season directories
organize_tv_show() {
    local dest_dir="$1"
    local torrent_name="$2"
    
    log "Organizing TV show: $torrent_name"
    
    # Extract show name and season info
    local show_name season_num
    if [[ "$torrent_name" =~ (.+)[._-]S([0-9]{1,2}) ]]; then
        show_name="${BASH_REMATCH[1]}"
        season_num="${BASH_REMATCH[2]}"
        
        # Clean show name (remove dots, underscores, etc.)
        show_name=$(echo "$show_name" | sed 's/[._-]/ /g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
        
        # Create show/season directory structure
        local show_dir="$dest_dir/$show_name/Season $((10#$season_num))"
        mkdir -p "$show_dir"
        
        log "Organizing into: $show_dir"
        
        # Move files to proper structure
        if [ -d "$dest_dir/$torrent_name" ]; then
            mv "$dest_dir/$torrent_name"/* "$show_dir/" 2>/dev/null || true
            rmdir "$dest_dir/$torrent_name" 2>/dev/null || true
        fi
    fi
}

# Notify Jellyfin to scan for new media
notify_jellyfin() {
    local media_type="$1"
    
    log "Notifying Jellyfin of new $media_type content"
    
    local jellyfin_url="http://jellyfin:8096"
    local api_key="${JELLYFIN_API_KEY:-}"
    
    if [ -n "$api_key" ]; then
        # Trigger library scan for specific media type
        local library_id
        case "$media_type" in
            "movies") library_id="movies" ;;
            "tv") library_id="tv" ;;
            "music") library_id="music" ;;
            "books") library_id="books" ;;
            *) library_id="" ;;
        esac
        
        if [ -n "$library_id" ]; then
            curl -X POST \
                "${jellyfin_url}/Library/Refresh" \
                -H "X-Emby-Token: ${api_key}" \
                -H "Content-Type: application/json" \
                -d "{\"ItemIds\":[],\"ImageRefreshMode\":\"Default\",\"MetadataRefreshMode\":\"Default\",\"ReplaceAllImages\":false,\"ReplaceAllMetadata\":false}" \
                --max-time 30 --silent || log "WARNING: Failed to trigger Jellyfin library scan"
        else
            # General library refresh
            curl -X POST \
                "${jellyfin_url}/Library/Refresh" \
                -H "X-Emby-Token: ${api_key}" \
                --max-time 30 --silent || log "WARNING: Failed to trigger Jellyfin library scan"
        fi
    else
        log "INFO: No Jellyfin API key configured, skipping library notification"
        log "INFO: You can manually refresh the Jellyfin library or configure JELLYFIN_API_KEY"
    fi
}

# Clean up incomplete downloads
cleanup_incomplete() {
    local incomplete_dir="/downloads/incomplete"
    
    # Remove empty directories older than 1 day
    find "$incomplete_dir" -type d -empty -mtime +1 -delete 2>/dev/null || true
    
    # Remove partial files older than 7 days
    find "$incomplete_dir" -name "*.part" -mtime +7 -delete 2>/dev/null || true
}

# Main processing function
main() {
    log "=== Post-Download Processing Started ==="
    
    # Validate environment
    validate_env
    
    # Get torrent information
    local source_dir="$TR_TORRENT_DIR"
    local torrent_name="$TR_TORRENT_NAME"
    local full_source_path="$source_dir/$torrent_name"
    
    # Verify source exists
    if [ ! -e "$full_source_path" ]; then
        error_exit "Source path does not exist: $full_source_path"
    fi
    
    # Determine media type and destination
    local media_type
    media_type=$(determine_media_type "$torrent_name" "$full_source_path")
    local dest_dir="/media/$media_type"
    
    log "Media type determined: $media_type"
    log "Destination directory: $dest_dir"
    
    # Create hardlinks to media directory
    create_hardlinks "$source_dir" "$dest_dir" "$torrent_name"
    
    # Set proper permissions
    set_permissions "$dest_dir/$torrent_name"
    
    # Special handling for TV shows
    if [ "$media_type" = "tv" ]; then
        organize_tv_show "$dest_dir" "$torrent_name"
    fi
    
    # Notify Jellyfin
    notify_jellyfin "$media_type"
    
    # Cleanup old incomplete downloads
    cleanup_incomplete
    
    log "=== Post-Download Processing Completed Successfully ==="
    log "Content available at: $dest_dir"
    
    # Optional: Send notification
    if command -v notify-send &> /dev/null; then
        notify-send "Media Server" "Download completed: $torrent_name" 2>/dev/null || true
    fi
}

# Error trap
trap 'log "ERROR: Post-download script failed at line $LINENO"' ERR

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

# Run main function
main "$@"