#!/bin/bash
# Enhanced interactive media deletion script with comprehensive TV/Movie support

DOWNLOADS_DIR="/mnt/storage/downloads/complete"
MOVIES_DIR="/mnt/storage/media/movies"
TV_DIR="/mnt/storage/media/tv"

echo "=== Enhanced Media Deletion Tool ==="
echo "Scanning downloads directory: $DOWNLOADS_DIR"
echo

# Check if downloads directory exists
if [ ! -d "$DOWNLOADS_DIR" ]; then
    echo "Error: Downloads directory not found: $DOWNLOADS_DIR"
    exit 1
fi

# Simple approach - use ls and process each line
cd "$DOWNLOADS_DIR" || exit 1
echo "Available items for deletion:"
echo "0) Cancel (exit without deleting)"

# Create indexed list
counter=1
declare -a items
while IFS= read -r item; do
    if [ -n "$item" ]; then
        items[$counter]="$item"
        echo "$counter) $item"
        counter=$((counter + 1))
    fi
done < <(ls -1)

if [ ${#items[@]} -eq 0 ]; then
    echo "No items found in downloads directory."
    exit 0
fi

echo
echo -n "Select item to delete (0-$((counter-1))): "
read selection

# Validate selection
if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
    echo "Invalid selection. Must be a number."
    exit 1
fi

if [ "$selection" -eq 0 ]; then
    echo "Operation cancelled."
    exit 0
fi

if [ "$selection" -lt 1 ] || [ "$selection" -ge "$counter" ]; then
    echo "Invalid selection. Please enter a number between 0 and $((counter-1))."
    exit 1
fi

selected_item="${items[$selection]}"

echo
echo "Selected: $selected_item"
echo

# Confirm deletion
echo -n "Are you sure you want to delete \"$selected_item\"? (y/N): "
read confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

echo
echo "Deleting: $selected_item"

# Delete from downloads directory
downloads_path="$DOWNLOADS_DIR/$selected_item"
if [ -e "$downloads_path" ]; then
    echo "Removing from downloads: $downloads_path"
    rm -rf "$downloads_path"
    if [ $? -eq 0 ]; then
        echo "✓ Successfully removed from downloads"
    else
        echo "✗ Failed to remove from downloads"
        exit 1
    fi
else
    echo "Item not found in downloads directory"
    exit 1
fi

# Enhanced media cleanup function
cleanup_media_files() {
    local search_name="$1"
    local search_dirs=("$MOVIES_DIR" "$TV_DIR")
    local found_items=()
    
    echo
    echo "=== Comprehensive Media Cleanup ==="
    echo "Searching for media files related to: $search_name"
    
    # Clean and prepare search terms
    clean_name="$search_name"
    
    # Remove year patterns like (2023) or [2023]
    clean_name=$(echo "$clean_name" | sed 's/[[(][0-9][0-9][0-9][0-9][])]//g')
    
    # Remove common release patterns
    clean_name=$(echo "$clean_name" | sed -E 's/\[[^]]*\]//g')  # Remove [anything]
    clean_name=$(echo "$clean_name" | sed -E 's/\([^)]*p\)//g')  # Remove (1080p), (720p), etc.
    clean_name=$(echo "$clean_name" | sed -E 's/(BluRay|HDTV|WEB-DL|x264|x265|HEVC|AAC|AC3|5\.1).*//i')
    clean_name=$(echo "$clean_name" | sed -E 's/(REPACK|PROPER|UNCUT|EXTENDED|DIRECTORS?|CUT).*//i')
    
    # Clean up extra spaces and get meaningful words
    clean_name=$(echo "$clean_name" | sed 's/[^a-zA-Z0-9 ]/ /g' | sed 's/  */ /g' | sed 's/^ *//' | sed 's/ *$//')
    
    echo "Cleaned search name: $clean_name"
    
    # Extract search words (minimum 3 characters, maximum 4 words)
    search_words=()
    word_count=0
    for word in $clean_name; do
        if [ ${#word} -gt 2 ] && [ $word_count -lt 4 ]; then
            search_words+=("$word")
            word_count=$((word_count + 1))
        fi
    done
    
    if [ ${#search_words[@]} -eq 0 ]; then
        echo "No valid search terms found"
        return 0
    fi
    
    echo "Search terms: ${search_words[*]}"
    
    # Search in both movies and TV directories
    for search_dir in "${search_dirs[@]}"; do
        if [ ! -d "$search_dir" ]; then
            echo "Skipping non-existent directory: $search_dir"
            continue
        fi
        
        echo "Searching in: $search_dir"
        
        # Strategy 1: Exact or near-exact directory name match
        while IFS= read -r -d '' item; do
            if [ -n "$item" ] && [[ ! " ${found_items[*]} " =~ " $item " ]]; then
                found_items+=("$item")
                echo "  Found (exact match): $item"
            fi
        done < <(find "$search_dir" -maxdepth 2 -type d -iname "*$clean_name*" -print0 2>/dev/null)
        
        # Strategy 2: Search for individual words
        for search_word in "${search_words[@]}"; do
            if [ ${#search_word} -gt 2 ]; then
                echo "  Searching for word: $search_word"
                
                # Find directories containing the search word
                while IFS= read -r -d '' item; do
                    if [ -n "$item" ] && [[ ! " ${found_items[*]} " =~ " $item " ]]; then
                        found_items+=("$item")
                        echo "    Found: $item"
                    fi
                done < <(find "$search_dir" -maxdepth 2 -type d -iname "*$search_word*" -print0 2>/dev/null)
            fi
        done
        
        # Strategy 3: Combined search for first 2-3 words
        if [ ${#search_words[@]} -ge 2 ]; then
            combined_search="${search_words[0]}"
            if [ ${#search_words[@]} -ge 2 ]; then
                combined_search+=" ${search_words[1]}"
            fi
            if [ ${#search_words[@]} -ge 3 ]; then
                combined_search+=" ${search_words[2]}"
            fi
            
            echo "  Searching for combined: $combined_search"
            
            # Search with wildcards between words
            combined_pattern=$(echo "$combined_search" | sed 's/ /*/g')
            while IFS= read -r -d '' item; do
                if [ -n "$item" ] && [[ ! " ${found_items[*]} " =~ " $item " ]]; then
                    found_items+=("$item")
                    echo "    Found (combined): $item"
                fi
            done < <(find "$search_dir" -maxdepth 2 -type d -iname "*$combined_pattern*" -print0 2>/dev/null)
        fi
        
        # Strategy 4: Search for files directly (for single episode deletions)
        for search_word in "${search_words[@]}"; do
            if [ ${#search_word} -gt 2 ]; then
                while IFS= read -r -d '' item; do
                    # Get the parent directory of the file
                    parent_dir=$(dirname "$item")
                    if [ -n "$parent_dir" ] && [[ ! " ${found_items[*]} " =~ " $parent_dir " ]]; then
                        found_items+=("$parent_dir")
                        echo "    Found (file parent): $parent_dir"
                    fi
                done < <(find "$search_dir" -type f -iname "*$search_word*" -print0 2>/dev/null)
            fi
        done
    done
    
    # Remove duplicates and sort
    if [ ${#found_items[@]} -gt 0 ]; then
        # Convert to unique sorted list
        IFS=$'\n' sorted_items=($(printf "%s\n" "${found_items[@]}" | sort -u))
        
        echo
        echo "Found ${#sorted_items[@]} unique media item(s):"
        for i in "${!sorted_items[@]}"; do
            echo "  $((i+1)). ${sorted_items[i]}"
            
            # Show contents if it's a directory
            if [ -d "${sorted_items[i]}" ]; then
                file_count=$(find "${sorted_items[i]}" -type f -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" 2>/dev/null | wc -l)
                dir_size=$(du -sh "${sorted_items[i]}" 2>/dev/null | cut -f1)
                echo "      ($file_count video files, $dir_size)"
            fi
        done
        
        echo
        echo -n "Delete these media items? (y/N): "
        read confirm_media
        if [[ "$confirm_media" =~ ^[Yy]$ ]]; then
            deletion_errors=0
            for item in "${sorted_items[@]}"; do
                if [ -e "$item" ]; then
                    echo "Deleting: $item"
                    rm -rf "$item"
                    if [ $? -eq 0 ]; then
                        echo "✓ Successfully removed: $item"
                    else
                        echo "✗ Failed to remove: $item"
                        deletion_errors=$((deletion_errors + 1))
                    fi
                else
                    echo "⚠ Item no longer exists: $item"
                fi
            done
            
            # Clean up empty parent directories recursively
            echo
            echo "Cleaning up empty directories..."
            for search_dir in "${search_dirs[@]}"; do
                if [ -d "$search_dir" ]; then
                    # Run multiple passes to handle nested empty directories
                    for pass in {1..5}; do
                        empty_dirs_removed=$(find "$search_dir" -type d -empty -delete -print 2>/dev/null | wc -l)
                        if [ $empty_dirs_removed -eq 0 ]; then
                            break
                        fi
                        echo "  Pass $pass: Removed $empty_dirs_removed empty directories"
                    done
                fi
            done
            
            if [ $deletion_errors -eq 0 ]; then
                echo "✓ All media files successfully deleted"
            else
                echo "⚠ $deletion_errors errors occurred during deletion"
            fi
        else
            echo "Media deletion cancelled"
        fi
    else
        echo "No matching media files found"
    fi
}

# Call the enhanced cleanup function
cleanup_media_files "$selected_item"

# Refresh Jellyfin library
echo
echo "Triggering Jellyfin library refresh..."
curl -s -X POST "http://localhost:8096/Library/Refresh" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✓ Jellyfin refresh triggered"
else
    echo "⚠ Failed to trigger Jellyfin refresh (service may be down)"
fi

echo
echo "=== Deletion Process Complete! ==="

# Final cleanup verification
echo
echo "Performing final cleanup verification..."
total_freed=0

# Check for any remaining empty directories
for search_dir in "$MOVIES_DIR" "$TV_DIR"; do
    if [ -d "$search_dir" ]; then
        empty_count=$(find "$search_dir" -type d -empty 2>/dev/null | wc -l)
        if [ $empty_count -gt 0 ]; then
            echo "Found $empty_count empty directories in $search_dir - cleaning up..."
            find "$search_dir" -type d -empty -delete 2>/dev/null
        fi
    fi
done

echo "Cleanup verification complete!"
