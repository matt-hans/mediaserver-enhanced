# Torrent Search & Download Tool

## Overview
This script integrates with your Jackett indexers and Transmission client to search and download torrents directly from the command line.

## Features
- Search multiple torrent indexers via Jackett
- Category filtering (Movies, TV, Music, Books, Games)
- Interactive selection and download
- Real-time Transmission status monitoring
- Colored output for better readability

## Usage

### Start the Interactive Tool
```bash
python3 torrent_downloader.py
```

### Search Examples
1. General search: Enter any search term
2. Movies: Select category 2 and search for movie titles
3. TV Shows: Select category 3 and search for series names
4. Music: Select category 4 and search for artists/albums

### Download Process
1. Run a search
2. Browse the results (shows first 20)
3. Enter the number of your chosen torrent
4. The script will automatically add it to Transmission

### Monitor Downloads
- Use option 2 in the main menu to see active torrents
- Check progress, speeds, and status
- Or visit http://192.168.2.2:9091 in your browser

## Service URLs
- **Jackett**: http://192.168.2.2:9117
- **Transmission**: http://192.168.2.2:9091 (admin/invent-creat3)
- **Jellyfin**: http://192.168.2.2:8096

## API Information
- **Jackett API Key**: g0a8u9ri90ezjjw54grllpaflsgfgcnc
- **Torznab URL**: http://192.168.2.2:9117/api/v2.0/indexers/all/results/torznab/

## Note
The script automatically handles:
- Jackett API authentication
- Transmission session management
- File downloads and torrent addition
- Error handling and user feedback
