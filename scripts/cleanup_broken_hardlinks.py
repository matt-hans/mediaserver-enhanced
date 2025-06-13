#\!/usr/bin/env python3
import os
import sys
from pathlib import Path

def find_broken_hardlinks():
    """Find original files in downloads that no longer have corresponding hardlinks in media"""
    downloads_dir = Path('/mnt/storage/downloads/complete')
    media_dir = Path('/mnt/storage/media')
    
    broken_files = []
    
    # Get all video files in downloads
    for file_path in downloads_dir.rglob('*'):
        if file_path.is_file() and file_path.suffix.lower() in ['.mkv', '.mp4', '.avi', '.mov']:
            # Check if this file has hardlinks in media directory
            stat_info = file_path.stat()
            hardlink_count = stat_info.st_nlink
            
            if hardlink_count == 1:  # Only original file exists, no hardlinks
                print(f"Found orphaned file: {file_path}")
                broken_files.append(file_path)
    
    return broken_files

def cleanup_orphaned_files():
    """Remove original files that no longer have hardlinks in media"""
    orphaned = find_broken_hardlinks()
    
    if not orphaned:
        print("No orphaned files found.")
        return
    
    print(f"\nFound {len(orphaned)} orphaned files:")
    for file_path in orphaned:
        print(f"  {file_path}")
    
    response = input("\nDelete these orphaned files? (y/N): ").strip().lower()
    if response == 'y':
        for file_path in orphaned:
            try:
                file_path.unlink()
                print(f"Deleted: {file_path}")
                
                # Also remove empty parent directories
                parent = file_path.parent
                if parent != Path('/mnt/storage/downloads/complete') and not any(parent.iterdir()):
                    parent.rmdir()
                    print(f"Removed empty directory: {parent}")
            except Exception as e:
                print(f"Error deleting {file_path}: {e}")
    else:
        print("Cleanup cancelled.")

if __name__ == "__main__":
    cleanup_orphaned_files()
