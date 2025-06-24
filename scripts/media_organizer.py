#\!/usr/bin/env python3
"""
Media Organizer with Hard Links - External Storage Version
Fixed version with proper title casing for Jellyfin compatibility
"""

import os
import re
import sys
import json
import shutil
import subprocess
from pathlib import Path
from urllib.parse import quote
import requests

# Configuration - Updated for external storage
DOWNLOAD_DIR = Path("/mnt/storage/downloads/complete")
MOVIES_DIR = Path("/mnt/storage/media/movies")
TV_DIR = Path("/mnt/storage/media/tv")
LOG_DIR = Path("/home/matthewhans/mediaserver-enhanced/logs")

# Video file extensions
VIDEO_EXTENSIONS = {'.mkv', '.mp4', '.avi', '.mov', '.m4v', '.wmv', '.flv', '.webm', '.ts', '.m2ts'}

class MediaOrganizer:
    def __init__(self):
        self.log_file = LOG_DIR / 'media_organizer.log'
        LOG_DIR.mkdir(exist_ok=True)
        MOVIES_DIR.mkdir(exist_ok=True)
        TV_DIR.mkdir(exist_ok=True)
    
    def log(self, message):
        """Log message to file and stdout"""
        timestamp = subprocess.check_output(['date'], text=True).strip()
        log_entry = f"[{timestamp}] {message}"
        print(log_entry)
        
        with open(self.log_file, 'a') as f:
            f.write(log_entry + '\n')
    
    def title_case(self, text):
        """Convert text to proper title case, handling special cases"""
        # List of words that should remain lowercase
        lowercase_words = {'a', 'an', 'and', 'as', 'at', 'but', 'by', 'for', 'from', 
                          'in', 'of', 'on', 'or', 'the', 'to', 'with'}
        
        words = text.split()
        result = []
        
        for i, word in enumerate(words):
            # Always capitalize first and last word
            if i == 0 or i == len(words) - 1:
                result.append(word.capitalize())
            elif word.lower() in lowercase_words:
                result.append(word.lower())
            else:
                result.append(word.capitalize())
        
        return ' '.join(result)
    
    def parse_filename(self, filename):
        """Parse filename to extract media information"""
        # Remove file extension
        name = Path(filename).stem
        
        # Common patterns
        year_pattern = r'[\(\[]?(19|20)\d{2}[\)\]]?'
        season_episode_pattern = r'[Ss](\d{1,2})[Ee](\d{1,2})'
        resolution_pattern = r'(720p|1080p|2160p|4K)'
        
        info = {
            'original_name': name,
            'title': '',
            'year': None,
            'season': None,
            'episode': None,
            'resolution': '',
            'is_tv': False
        }
        
        # Check for season/episode (TV show)
        se_match = re.search(season_episode_pattern, name, re.IGNORECASE)
        if se_match:
            info['is_tv'] = True
            info['season'] = int(se_match.group(1))
            info['episode'] = int(se_match.group(2))
            # Title is everything before the season/episode
            info['title'] = re.split(season_episode_pattern, name, flags=re.IGNORECASE)[0]
        else:
            # Extract year for movies
            year_match = re.search(year_pattern, name)
            if year_match:
                info['year'] = int(year_match.group(0).strip('()[]'))
                # Title is everything before the year
                info['title'] = re.split(year_pattern, name)[0]
            else:
                # No year found, use whole name as title
                info['title'] = name
        
        # Clean up title
        info['title'] = re.sub(r'[\._-]+', ' ', info['title']).strip()
        info['title'] = re.sub(r'\s+', ' ', info['title'])
        
        # Apply proper title casing
        info['title'] = self.title_case(info['title'])
        
        # Extract resolution
        res_match = re.search(resolution_pattern, name, re.IGNORECASE)
        if res_match:
            info['resolution'] = res_match.group(1)
        
        return info
    
    def create_hardlink(self, source_path, dest_path):
        """Create a hard link from source to destination"""
        try:
            dest_path.parent.mkdir(parents=True, exist_ok=True)
            
            # Remove existing file if it exists
            if dest_path.exists():
                dest_path.unlink()
            
            # Create hard link
            os.link(source_path, dest_path)
            self.log(f"✓ Hard linked: {source_path.name} -> {dest_path}")
            return True
            
        except Exception as e:
            self.log(f"✗ Failed to link {source_path.name}: {e}")
            return False
    
    def organize_movie(self, file_path, info):
        """Organize a movie file"""
        title = info['title']
        year = info['year']
        
        # Create directory name
        if year:
            dir_name = f"{title} ({year})"
        else:
            dir_name = title
        
        # Sanitize directory name
        dir_name = re.sub(r'[<>:"/\\|?*]', '', dir_name)
        
        movie_dir = MOVIES_DIR / dir_name
        dest_path = movie_dir / file_path.name
        
        return self.create_hardlink(file_path, dest_path)
    
    def organize_tv_show(self, file_path, info):
        """Organize a TV show file"""
        title = info['title']
        season = info['season']
        episode = info['episode']
        
        # Sanitize show name
        show_name = re.sub(r'[<>:"/\\|?*]', '', title)
        
        # Create directory structure
        show_dir = TV_DIR / show_name / f"Season {season:02d}"
        
        # Create episode filename with proper formatting
        # Use title case for the show name in the filename too
        episode_name = f"{show_name} - S{season:02d}E{episode:02d}{file_path.suffix}"
        dest_path = show_dir / episode_name
        
        return self.create_hardlink(file_path, dest_path)
    
    def find_video_files(self, directory):
        """Find all video files in directory recursively"""
        video_files = []
        
        for root, dirs, files in os.walk(directory):
            for file in files:
                if Path(file).suffix.lower() in VIDEO_EXTENSIONS:
                    video_files.append(Path(root) / file)
        
        return video_files
    
    def organize_file(self, file_path):
        """Organize a single file"""
        self.log(f"Processing: {file_path.name}")
        
        # Parse filename
        info = self.parse_filename(file_path.name)
        self.log(f"Parsed as: {info}")
        
        # Organize based on type
        if info['is_tv']:
            success = self.organize_tv_show(file_path, info)
        else:
            success = self.organize_movie(file_path, info)
        
        return success
    
    def organize_directory(self, target_dir=None):
        """Organize all files in the downloads directory"""
        if target_dir is None:
            target_dir = DOWNLOAD_DIR
        
        target_dir = Path(target_dir)
        
        if not target_dir.exists():
            self.log(f"Directory {target_dir} does not exist")
            return
        
        self.log(f"Organizing files in: {target_dir}")
        
        # Find all video files
        video_files = self.find_video_files(target_dir)
        
        if not video_files:
            self.log("No video files found")
            return
        
        self.log(f"Found {len(video_files)} video files")
        
        # Organize each file
        organized_count = 0
        for video_file in video_files:
            if self.organize_file(video_file):
                organized_count += 1
        
        self.log(f"Successfully organized {organized_count}/{len(video_files)} files")
    
    def scan_jellyfin_libraries(self):
        """Trigger Jellyfin library scan (if available)"""
        try:
            # Try to connect to Jellyfin and trigger a library scan
            jellyfin_url = 'http://localhost:8096'
            response = requests.get(f"{jellyfin_url}/health", timeout=5)
            if response.status_code == 200:
                self.log("Jellyfin is running - library scan would be triggered here")
            else:
                self.log("Jellyfin not accessible for library scan")
        except:
            self.log("Jellyfin not available for library scan")

def main():
    organizer = MediaOrganizer()
    
    if len(sys.argv) > 1:
        # Organize specific directory (called by Transmission)
        target_dir = sys.argv[1]
        organizer.log(f"Called by Transmission for: {target_dir}")
        organizer.organize_directory(target_dir)
    else:
        # Organize entire downloads directory
        organizer.log("Manual organization run")
        organizer.organize_directory()
    
    # Trigger Jellyfin library scan
    organizer.scan_jellyfin_libraries()

if __name__ == '__main__':
    main()
