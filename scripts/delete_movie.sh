#!/bin/bash
# Professional-grade media deletion script with surgical precision
# Version 2.0 - Complete rewrite with hardlink detection and safety features

set -euo pipefail

# Configuration
DOWNLOADS_DIR="/mnt/storage/downloads/complete"
MOVIES_DIR="/mnt/storage/media/movies"
TV_DIR="/mnt/storage/media/tv"
ALLOWED_ROOTS=("$MOVIES_DIR" "$TV_DIR")
MAX_DELETIONS_PER_RUN=10
DELETE_COUNT=0
DRY_RUN=true
VERBOSE=false
LOG_FILE="/tmp/delete_movie_$(date +%Y%m%d_%H%M%S).log"

# Jellyfin configuration
JELLYFIN_URL="http://localhost:8096"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[LOG]${NC} $message"
    fi
}

# Error handling
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    log "ERROR: $1"
    exit 1
}

# Warning message
warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
    log "WARNING: $1"
}

# Success message
success() {
    echo -e "${GREEN}✓ $1${NC}"
    log "SUCCESS: $1"
}

# Check if path is under allowed roots
is_under_allowed_root() {
    local path="$1"
    local abspath
    abspath="$(readlink -f -- "$path" 2>/dev/null)" || return 1
    
    for root in "${ALLOWED_ROOTS[@]}"; do
        local abroot
        abroot="$(readlink -f -- "$root" 2>/dev/null)" || continue
        if [[ "$abspath" == "$abroot"* ]]; then
            return 0
        fi
    done
    return 1
}

# Find exact hardlink match
find_hardlink_target() {
    local src="$1"
    local inode device
    
    # Get inode and device of source file
    if [[ ! -f "$src" ]]; then
        return 1
    fi
    
    # Get inode number
    inode=$(stat -c %i "$src" 2>/dev/null) || return 1
    device=$(stat -c %d "$src" 2>/dev/null) || return 1
    
    log "Searching for hardlink with inode $inode on device $device"
    
    # Search for files with same inode
    local matches=()
    for root in "${ALLOWED_ROOTS[@]}"; do
        while IFS= read -r -d '' file; do
            if [[ "$file" != "$src" ]]; then
                local file_inode file_device
                file_inode=$(stat -c %i "$file" 2>/dev/null) || continue
                file_device=$(stat -c %d "$file" 2>/dev/null) || continue
                if [[ "$file_inode" == "$inode" && "$file_device" == "$device" ]]; then
                    matches+=("$file")
                fi
            fi
        done < <(find "$root" -type f -print0 2>/dev/null)
    done
    
    if [[ ${#matches[@]} -eq 1 ]]; then
        echo "${matches[0]}"
        return 0
    elif [[ ${#matches[@]} -gt 1 ]]; then
        warning "Multiple hardlink targets found for: $src"
        for match in "${matches[@]}"; do
            warning "  - $match"
        done
        return 2
    fi
    
    return 1
}

# Extract TV episode pattern
extract_episode_pattern() {
    local filename="$1"
    local pattern
    
    # Try S##E## pattern
    pattern=$(echo "$filename" | grep -Eio 's[0-9]{1,2}e[0-9]{1,2}' | head -n1) || true
    if [[ -n "$pattern" ]]; then
        echo "$pattern"
        return 0
    fi
    
    # Try ##x## pattern
    pattern=$(echo "$filename" | grep -Eio '[0-9]{1,2}x[0-9]{1,2}' | head -n1) || true
    if [[ -n "$pattern" ]]; then
        echo "$pattern"
        return 0
    fi
    
    return 1
}

# TV episode fallback matching
find_tv_episode_match() {
    local src="$1"
    local basename size pattern
    
    basename="$(basename "$src")"
    size="$(stat -c %s "$src" 2>/dev/null)" || return 1
    pattern="$(extract_episode_pattern "$basename")" || return 1
    
    log "TV fallback: searching for pattern '$pattern' with size $size bytes"
    
    local matches=()
    while IFS= read -r -d '' file; do
        local file_size
        file_size="$(stat -c %s "$file" 2>/dev/null)" || continue
        if [[ "$file_size" -eq "$size" ]]; then
            matches+=("$file")
        fi
    done < <(find "$TV_DIR" -type f -iname "*${pattern}*" -print0 2>/dev/null)
    
    if [[ ${#matches[@]} -eq 1 ]]; then
        echo "${matches[0]}"
        return 0
    elif [[ ${#matches[@]} -gt 1 ]]; then
        warning "Multiple TV episode matches found for pattern $pattern"
        return 2
    fi
    
    return 1
}

# Movie fallback matching
find_movie_match() {
    local src="$1"
    local basename size year
    
    basename="$(basename "$src")"
    size="$(stat -c %s "$src" 2>/dev/null)" || return 1
    
    # Extract year (prefer last occurrence)
    year="$(echo "$basename" | grep -Eo '(19|20)[0-9]{2}' | tail -n1)" || return 1
    
    log "Movie fallback: searching for year $year with size $size bytes"
    
    local matches=()
    while IFS= read -r -d '' file; do
        local file_size
        file_size="$(stat -c %s "$file" 2>/dev/null)" || continue
        if [[ "$file_size" -eq "$size" ]]; then
            matches+=("$file")
        fi
    done < <(find "$MOVIES_DIR" -type f -path "*/\*($year)\*/*" -print0 2>/dev/null)
    
    if [[ ${#matches[@]} -eq 1 ]]; then
        echo "${matches[0]}"
        return 0
    elif [[ ${#matches[@]} -gt 1 ]]; then
        warning "Multiple movie matches found for year $year"
        return 2
    fi
    
    return 1
}

# Delete file with confirmation
delete_file() {
    local file="$1"
    local file_size_mb
    
    if [[ ! -e "$file" ]]; then
        warning "File not found: $file"
        return 1
    fi
    
    # Check if under allowed roots
    if ! is_under_allowed_root "$file"; then
        error_exit "File is outside allowed directories: $file"
    fi
    
    # Get file size in MB
    file_size_mb=$(du -h "$file" 2>/dev/null | cut -f1)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would delete: $file ($file_size_mb)"
        log "DRY-RUN: Would delete $file"
    else
        rm -f "$file"
        if [[ $? -eq 0 ]]; then
            success "Deleted: $file ($file_size_mb)"
            log "DELETED: $file"
            ((DELETE_COUNT++))
            
            # Clean up empty parent directories
            local parent_dir="$(dirname "$file")"
            while [[ "$parent_dir" != "/" ]]; do
                # Check if directory is empty and safe to remove
                if [[ -d "$parent_dir" ]] && [[ -z "$(ls -A "$parent_dir" 2>/dev/null)" ]]; then
                    # Don't remove the root media directories
                    if [[ "$parent_dir" != "$MOVIES_DIR" && "$parent_dir" != "$TV_DIR" ]]; then
                        rmdir "$parent_dir" 2>/dev/null && log "Removed empty directory: $parent_dir"
                    else
                        break
                    fi
                else
                    break
                fi
                parent_dir="$(dirname "$parent_dir")"
            done
        else
            warning "Failed to delete: $file"
            return 1
        fi
    fi
    
    return 0
}

# Main deletion logic
process_deletion() {
    local selected_item="$1"
    local download_path="$DOWNLOADS_DIR/$selected_item"
    
    echo
    echo "═══════════════════════════════════════════"
    echo "   PRECISE DELETION MODE"
    echo "═══════════════════════════════════════════"
    echo
    
    # First, delete from downloads
    echo "Step 1: Deleting from downloads directory"
    if [[ -e "$download_path" ]]; then
        delete_file "$download_path"
    else
        warning "Not found in downloads: $download_path"
    fi
    
    # Find corresponding media file
    echo
    echo "Step 2: Finding corresponding media file"
    
    local media_file=""
    local match_method=""
    
    # Try hardlink detection first
    if media_file=$(find_hardlink_target "$download_path" 2>/dev/null); then
        match_method="hardlink"
        success "Found exact match via hardlink"
    # Try TV episode pattern
    elif media_file=$(find_tv_episode_match "$download_path" 2>/dev/null); then
        match_method="tv-pattern"
        success "Found TV episode match"
    # Try movie pattern
    elif media_file=$(find_movie_match "$download_path" 2>/dev/null); then
        match_method="movie-pattern"
        success "Found movie match"
    else
        warning "No media file match found"
        echo "Only the download file was deleted."
        return 0
    fi
    
    if [[ -n "$media_file" ]]; then
        echo
        echo "Match method: $match_method"
        echo "Media file: $media_file"
        echo
        
        # Confirm before deleting media file
        if [[ "$DRY_RUN" == "false" ]]; then
            echo -n "Delete this media file? [y/N]: "
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                delete_file "$media_file"
            else
                echo "Skipped media file deletion"
            fi
        else
            delete_file "$media_file"
        fi
    fi
    
    # Check deletion limit
    if [[ $DELETE_COUNT -ge $MAX_DELETIONS_PER_RUN ]]; then
        warning "Reached maximum deletions limit ($MAX_DELETIONS_PER_RUN)"
        echo "Please run the script again if you need to delete more files."
        exit 0
    fi
}

# Trigger Jellyfin library refresh
refresh_jellyfin() {
    echo
    echo "Step 3: Refreshing Jellyfin library"
    
    # Trigger library scan
    if curl -sS -X POST "$JELLYFIN_URL/Library/Refresh" >/dev/null 2>&1; then
        success "Jellyfin library refresh triggered"
    else
        warning "Failed to trigger Jellyfin refresh (service may be down)"
    fi
}

# Display usage
usage() {
    cat << USAGE
Usage: $0 [OPTIONS]

Professional media deletion tool with surgical precision.

OPTIONS:
    --confirm       Execute deletions (default is dry-run mode)
    --verbose       Show detailed logging
    --help          Display this help message

SAFETY FEATURES:
    - Dry-run mode by default (use --confirm to actually delete)
    - Maximum $MAX_DELETIONS_PER_RUN deletions per run
    - Precise file matching (no fuzzy search)
    - Detailed logging to $LOG_FILE

MATCHING METHODS:
    1. Hardlink detection (exact inode match)
    2. TV episode pattern (S##E## + file size)
    3. Movie pattern (year + file size)

USAGE
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --confirm)
            DRY_RUN=false
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            error_exit "Unknown option: $1 (use --help for usage)"
            ;;
    esac
done

# Main script
main() {
    echo "═══════════════════════════════════════════════════════════"
    echo "        PROFESSIONAL MEDIA DELETION TOOL v2.0"
    echo "═══════════════════════════════════════════════════════════"
    echo
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}Running in DRY-RUN mode (no files will be deleted)${NC}"
        echo -e "${YELLOW}Use --confirm flag to actually delete files${NC}"
    else
        echo -e "${RED}DELETION MODE ACTIVE - Files will be permanently deleted!${NC}"
    fi
    
    echo
    log "Script started - DRY_RUN=$DRY_RUN"
    
    # Check if downloads directory exists
    if [[ ! -d "$DOWNLOADS_DIR" ]]; then
        error_exit "Downloads directory not found: $DOWNLOADS_DIR"
    fi
    
    # List available items
    echo "Scanning downloads directory: $DOWNLOADS_DIR"
    echo
    
    # Create array of items
    mapfile -t items < <(ls -1 "$DOWNLOADS_DIR" 2>/dev/null)
    
    if [[ ${#items[@]} -eq 0 ]]; then
        echo "No items found in downloads directory."
        exit 0
    fi
    
    echo "Available items:"
    echo "0) Exit"
    for i in "${!items[@]}"; do
        local item_size
        item_size=$(du -sh "$DOWNLOADS_DIR/${items[$i]}" 2>/dev/null | cut -f1)
        printf "%3d) %s [%s]\n" $((i+1)) "${items[$i]}" "$item_size"
    done
    
    echo
    echo -n "Select item to delete (0-${#items[@]}): "
    read -r selection
    
    # Validate selection
    if [[ ! "$selection" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid selection: must be a number"
    fi
    
    if [[ $selection -eq 0 ]]; then
        echo "Operation cancelled."
        exit 0
    fi
    
    if [[ $selection -lt 1 || $selection -gt ${#items[@]} ]]; then
        error_exit "Invalid selection: out of range"
    fi
    
    # Get selected item
    local selected_item="${items[$((selection-1))]}"
    
    echo
    echo "Selected: $selected_item"
    echo
    
    # Confirm selection
    echo -n "Proceed with deletion analysis? [y/N]: "
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
    
    # Process deletion
    process_deletion "$selected_item"
    
    # Refresh Jellyfin
    refresh_jellyfin
    
    echo
    echo "═══════════════════════════════════════════════════════════"
    echo "                   OPERATION COMPLETE"
    echo "═══════════════════════════════════════════════════════════"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo
        echo -e "${YELLOW}This was a dry-run. No files were actually deleted.${NC}"
        echo -e "${YELLOW}Run with --confirm flag to perform actual deletion.${NC}"
    else
        echo
        success "Files deleted: $DELETE_COUNT"
    fi
    
    echo
    echo "Log file: $LOG_FILE"
    log "Script completed - Files deleted: $DELETE_COUNT"
}

# Run main function
main
