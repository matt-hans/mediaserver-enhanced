#\!/usr/bin/env python3
"""
Torrent Search and Download Script
Integrates with Jackett indexers and Transmission client
"""

import requests
import json
import base64
import sys
import os
from urllib.parse import quote_plus

# Configuration
JACKETT_API_KEY = "g0a8u9ri90ezjjw54grllpaflsgfgcnc"
JACKETT_URL = "http://localhost:9117"
TRANSMISSION_USER = "admin"
TRANSMISSION_PASS = "invent-creat3"
TRANSMISSION_URL = "http://localhost:9091/transmission/rpc"

# Colors
class Colors:
    RED = "\\033[0;31m"
    GREEN = "\\033[0;32m"
    YELLOW = "\\033[1;33m"
    BLUE = "\\033[0;34m"
    PURPLE = "\\033[0;35m"
    CYAN = "\\033[0;36m"
    NC = "\\033[0m"

def format_size(size):
    """Format file size in human readable format"""
    if size >= 1073741824:
        return f"{size/1073741824:.1f} GB"
    elif size >= 1048576:
        return f"{size/1048576:.1f} MB"
    elif size >= 1024:
        return f"{size/1024:.1f} KB"
    else:
        return f"{size} B"

def get_transmission_session():
    """Get Transmission session ID"""
    try:
        response = requests.get(TRANSMISSION_URL, auth=(TRANSMISSION_USER, TRANSMISSION_PASS))
        session_id = response.headers.get("X-Transmission-Session-Id")
        return session_id
    except:
        return None

def search_torrents(query, category="search"):
    """Search for torrents using Jackett API"""
    print(f"{Colors.BLUE}Searching for: {Colors.YELLOW}{query}{Colors.NC}")
    print(f"{Colors.BLUE}Category: {Colors.YELLOW}{category}{Colors.NC}")
    print()
    
    # Search using Jackett API
    search_url = f"{JACKETT_URL}/api/v2.0/indexers/all/results"
    params = {
        "apikey": JACKETT_API_KEY,
        "q": query,
        "t": category
    }
    
    print(f"{Colors.CYAN}Fetching results...{Colors.NC}")
    
    try:
        response = requests.get(search_url, params=params, timeout=30)
        response.raise_for_status()
        data = response.json()
    except Exception as e:
        print(f"{Colors.RED}Error: Failed to fetch search results - {e}{Colors.NC}")
        return []
    
    results = data.get("Results", [])
    
    if not results:
        print(f"{Colors.YELLOW}No results found.{Colors.NC}")
        return []
    
    print(f"Found {len(results)} results:")
    print()
    
    # Display first 20 results
    displayed_results = results[:20]
    
    for i, result in enumerate(displayed_results, 1):
        title = result.get("Title", "Unknown")
        size = result.get("Size", 0)
        seeders = result.get("Seeders", 0)
        peers = result.get("Peers", 0)
        tracker = result.get("Tracker", "Unknown")
        
        size_str = format_size(size)
        
        print(f"{i:2d}. {title[:70]}")
        print(f"    Size: {size_str:<12} Seeds: {seeders:<4} Peers: {peers:<4} Tracker: {tracker}")
        print()
    
    return displayed_results

def download_torrent(results, selection):
    """Download selected torrent to Transmission"""
    try:
        selection_idx = int(selection) - 1
        if selection_idx < 0 or selection_idx >= len(results):
            print(f"{Colors.RED}Error: Invalid selection{Colors.NC}")
            return False
            
        selected_torrent = results[selection_idx]
        torrent_url = selected_torrent.get("Link", "")
        title = selected_torrent.get("Title", "Unknown")
        
        if not torrent_url:
            print(f"{Colors.RED}Error: No download link available{Colors.NC}")
            return False
            
        print(f"{Colors.CYAN}Downloading: {title[:50]}...{Colors.NC}")
        
        # Get session ID
        session_id = get_transmission_session()
        if not session_id:
            print(f"{Colors.RED}Error: Could not get Transmission session{Colors.NC}")
            return False
        
        # Download torrent file
        try:
            torrent_response = requests.get(torrent_url, timeout=30)
            torrent_response.raise_for_status()
            torrent_data = base64.b64encode(torrent_response.content).decode("utf-8")
        except Exception as e:
            print(f"{Colors.RED}Error: Failed to download torrent file - {e}{Colors.NC}")
            return False
        
        # Add to Transmission
        headers = {
            "X-Transmission-Session-Id": session_id,
            "Content-Type": "application/json"
        }
        
        request_data = {
            "method": "torrent-add",
            "arguments": {
                "metainfo": torrent_data
            }
        }
        
        try:
            response = requests.post(
                TRANSMISSION_URL,
                auth=(TRANSMISSION_USER, TRANSMISSION_PASS),
                headers=headers,
                json=request_data,
                timeout=30
            )
            response.raise_for_status()
            result = response.json()
            
            if result.get("result") == "success":
                print(f"{Colors.GREEN}✓ Torrent added to Transmission successfully\!{Colors.NC}")
                print(f"{Colors.BLUE}Check your downloads at: http://192.168.2.2:9091{Colors.NC}")
                return True
            else:
                error_msg = result.get("result", "Unknown error")
                print(f"{Colors.RED}Error: Failed to add torrent - {error_msg}{Colors.NC}")
                return False
                
        except Exception as e:
            print(f"{Colors.RED}Error: Failed to communicate with Transmission - {e}{Colors.NC}")
            return False
            
    except ValueError:
        print(f"{Colors.RED}Error: Please enter a valid number{Colors.NC}")
        return False

def show_transmission_status():
    """Show current Transmission downloads"""
    print(f"{Colors.CYAN}Current Transmission Downloads:{Colors.NC}")
    print()
    
    session_id = get_transmission_session()
    if not session_id:
        print(f"{Colors.RED}Error: Could not connect to Transmission{Colors.NC}")
        return
    
    headers = {
        "X-Transmission-Session-Id": session_id,
        "Content-Type": "application/json"
    }
    
    request_data = {
        "method": "torrent-get",
        "arguments": {
            "fields": ["id", "name", "status", "percentDone", "downloadDir", "rateDownload", "rateUpload"]
        }
    }
    
    try:
        response = requests.post(
            TRANSMISSION_URL,
            auth=(TRANSMISSION_USER, TRANSMISSION_PASS),
            headers=headers,
            json=request_data,
            timeout=30
        )
        response.raise_for_status()
        data = response.json()
        
        torrents = data.get("arguments", {}).get("torrents", [])
        
        if not torrents:
            print("No active torrents.")
            return
        
        print(f"Active Torrents ({len(torrents)}):")
        print()
        
        status_map = {
            0: "Stopped", 1: "Check Wait", 2: "Check", 3: "Download Wait",
            4: "Downloading", 5: "Seed Wait", 6: "Seeding"
        }
        
        for torrent in torrents:
            name = torrent.get("name", "Unknown")
            status = torrent.get("status", 0)
            percent = torrent.get("percentDone", 0) * 100
            dl_rate = torrent.get("rateDownload", 0)
            ul_rate = torrent.get("rateUpload", 0)
            
            status_str = status_map.get(status, "Unknown")
            
            print(f"• {name[:60]}")
            print(f"  Status: {status_str:<12} Progress: {percent:6.1f}%")
            if dl_rate > 0 or ul_rate > 0:
                print(f"  Download: {dl_rate/1024:.1f} KB/s  Upload: {ul_rate/1024:.1f} KB/s")
            print()
            
    except Exception as e:
        print(f"{Colors.RED}Error: Could not get torrent status - {e}{Colors.NC}")

def main():
    """Main script logic"""
    print(f"{Colors.GREEN}=== Torrent Search & Download Tool ==={Colors.NC}")
    print(f"{Colors.BLUE}Connected to Jackett: {JACKETT_URL}{Colors.NC}")
    print(f"{Colors.BLUE}Connected to Transmission: http://localhost:9091{Colors.NC}")
    print()
    
    while True:
        print(f"{Colors.YELLOW}Options:{Colors.NC}")
        print("1. Search for torrents")
        print("2. View Transmission status")
        print("3. Exit")
        print()
        
        try:
            choice = input("Choose an option (1-3): ").strip()
        except KeyboardInterrupt:
            print(f"\\n{Colors.GREEN}Goodbye\!{Colors.NC}")
            sys.exit(0)
        
        if choice == "1":
            print()
            try:
                query = input("Enter search query: ").strip()
                if not query:
                    print(f"{Colors.RED}Error: Please enter a search query{Colors.NC}")
                    continue
                
                print()
                print(f"{Colors.YELLOW}Categories:{Colors.NC}")
                print("1. All (search)")
                print("2. Movies (movie)")
                print("3. TV Shows (tv)")
                print("4. Music (audio)")
                print("5. Books (book)")
                print("6. Games (pc)")
                print()
                
                cat_choice = input("Choose category (1-6, default 1): ").strip()
                
                category_map = {
                    "2": "movie",
                    "3": "tv", 
                    "4": "audio",
                    "5": "book",
                    "6": "pc"
                }
                category = category_map.get(cat_choice, "search")
                
                print()
                results = search_torrents(query, category)
                
                if results:
                    print()
                    selection = input("Enter number to download (or press Enter to skip): ").strip()
                    
                    if selection:
                        download_torrent(results, selection)
                
                print()
                
            except KeyboardInterrupt:
                print(f"\\n{Colors.YELLOW}Search cancelled.{Colors.NC}")
                print()
                
        elif choice == "2":
            print()
            show_transmission_status()
            print()
            
        elif choice == "3":
            print(f"{Colors.GREEN}Goodbye\!{Colors.NC}")
            break
            
        else:
            print(f"{Colors.RED}Invalid option. Please choose 1-3.{Colors.NC}")
            print()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\\n{Colors.GREEN}Goodbye\!{Colors.NC}")
        sys.exit(0)
