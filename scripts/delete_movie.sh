#\!/bin/bash
# Interactive movie deletion script with selection menu

DOWNLOADS_DIR="/mnt/storage/downloads/complete"
MEDIA_DIR="/mnt/storage/media/movies"

echo "=== Movie Deletion Tool ==="
echo "Scanning downloads directory: $DOWNLOADS_DIR"
echo

# Check if downloads directory exists
if [ \! -d "$DOWNLOADS_DIR" ]; then
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
if \! [[ "$selection" =~ ^[0-9]+$ ]]; then
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
if [[ \! "$confirm" =~ ^[Yy]$ ]]; then
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

# Search for related files in media directory using improved matching
echo
echo "Searching for related files in media directory..."

# Extract movie title more intelligently
# Remove common patterns and extract meaningful title parts
movie_title="$selected_item"

# Remove year patterns like (2023) or [2023]
movie_title=$(echo "$movie_title" | sed 's/[[(][0-9][0-9][0-9][0-9][])]//g')

# Remove common release patterns
movie_title=$(echo "$movie_title" | sed -E 's/\[[^]]*\]//g')  # Remove [anything]
movie_title=$(echo "$movie_title" | sed -E 's/\([^)]*p\)//g')  # Remove (1080p), (720p), etc.
movie_title=$(echo "$movie_title" | sed -E 's/(BluRay|HDTV|WEB-DL|x264|x265|HEVC|AAC|AC3|5\.1).*//i')

# Clean up extra spaces and get meaningful words
movie_title=$(echo "$movie_title" | sed 's/[^a-zA-Z0-9 ]/ /g' | sed 's/  */ /g' | sed 's/^ *//' | sed 's/ *$//')

# Extract first 2-3 meaningful words for searching
search_words=()
word_count=0
for word in $movie_title; do
    if [ ${#word} -gt 2 ] && [ $word_count -lt 3 ]; then
        search_words+=("$word")
        word_count=$((word_count + 1))
    fi
done

if [ ${#search_words[@]} -gt 0 ]; then
    # Try multiple search strategies
    echo "Searching for movies matching: ${search_words[*]}"
    
    # Strategy 1: Search with case insensitive partial match for each word
    found_items=()
    
    for search_word in "${search_words[@]}"; do
        if [ ${#search_word} -gt 2 ]; then
            echo "  Searching for: $search_word"
            
            # Find directories and files containing the search word (case insensitive)
            while IFS= read -r -d '' item; do
                if [[ \! " ${found_items[*]} " =~ " $item " ]]; then
                    found_items+=("$item")
                fi
            done < <(find "$MEDIA_DIR" -iname "*$search_word*" -print0 2>/dev/null)
        fi
    done
    
    # Strategy 2: Try searching with combined first few words
    if [ ${#search_words[@]} -ge 2 ]; then
        combined_search="${search_words[0]} ${search_words[1]}"
        echo "  Searching for combined: $combined_search"
        while IFS= read -r -d '' item; do
            if [[ \! " ${found_items[*]} " =~ " $item " ]]; then
                found_items+=("$item")
            fi
        done < <(find "$MEDIA_DIR" -iname "*$combined_search*" -print0 2>/dev/null)
    fi
    
    if [ ${#found_items[@]} -gt 0 ]; then
        echo
        echo "Found ${#found_items[@]} related item(s) in media directory:"
        for item in "${found_items[@]}"; do
            echo "  $item"
        done
        echo
        echo -n "Delete these media items too? (y/N): "
        read confirm_media
        if [[ "$confirm_media" =~ ^[Yy]$ ]]; then
            for item in "${found_items[@]}"; do
                if [ -e "$item" ]; then
                    rm -rf "$item"
                    if [ $? -eq 0 ]; then
                        echo "✓ Removed: $item"
                    else
                        echo "✗ Failed to remove: $item"
                    fi
                fi
            done
            
            # Clean up empty parent directories
            echo "Cleaning up empty directories..."
            find "$MEDIA_DIR" -type d -empty -delete 2>/dev/null
        fi
    else
        echo "No matching items found in media directory."
    fi
else
    echo "Could not determine search terms for media cleanup"
fi

echo
echo "Triggering Jellyfin library refresh..."
curl -s -X POST "http://localhost:8096/Library/Refresh" > /dev/null 2>&1
echo "✓ Jellyfin refresh triggered"

echo
echo "Deletion complete\!"
