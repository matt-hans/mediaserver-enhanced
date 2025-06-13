#\!/usr/bin/env python3
"""
Fixed Torrent Search Script with Better Error Handling
"""

import requests
import json
import base64
import sys

# Configuration
JACKETT_API_KEY = "g0a8u9ri90ezjjw54grllpaflsgfgcnc"
JACKETT_URL = "http://localhost:9117"
TRANSMISSION_USER = "admin"
TRANSMISSION_PASS = "invent-creat3"
TRANSMISSION_URL = "http://localhost:9091/transmission/rpc"

class Colors:
    RED = "\\033[0;31m"
    GREEN = "\\033[0;32m"
    YELLOW = "\\033[1;33m"
    BLUE = "\\033[0;34m"
    CYAN = "\\033[0;36m"
    NC = "\\033[0m"

def check_jackett_setup():
    """Check if Jackett has indexers configured"""
    try:
        response = requests.get(f"{JACKETT_URL}/api/v2.0/indexers", 
                              headers={"X-Api-Key": JACKETT_API_KEY}, 
                              timeout=10)
        
        if response.status_code == 200:
            indexers = response.json()
            if not indexers:
                print(f"{Colors.YELLOW}⚠ No indexers configured in Jackett\!{Colors.NC}")
                print(f"{Colors.BLUE}Please visit {JACKETT_URL} to add indexers:{Colors.NC}")
                print("1. Click Add Indexer")
                print("2. Add popular indexers like 1337x, RARBG, etc.")
                print("3. Click the + button next to each indexer")
                return False
            else:
                print(f"{Colors.GREEN}✓ Found {len(indexers)} configured indexers{Colors.NC}")
                return True
        else:
            print(f"{Colors.RED}Error: Cannot connect to Jackett API{Colors.NC}")
            return False
            
    except Exception as e:
        print(f"{Colors.RED}Error checking Jackett: {e}{Colors.NC}")
        return False

def search_torrents_fixed(query, category="search"):
    """Search torrents with better error handling"""
    print(f"{Colors.BLUE}Searching for: {Colors.YELLOW}{query}{Colors.NC}")
    
    # First check if Jackett is properly configured
    if not check_jackett_setup():
        return []
    
    # Try different search approaches
    search_params = [
        {"q": query, "t": category},      # With category
        {"q": query},                     # Without category  
        {"q": query, "t": "search"}       # Generic search
    ]
    
    for i, params in enumerate(search_params):
        try:
            params["apikey"] = JACKETT_API_KEY
            response = requests.get(f"{JACKETT_URL}/api/v2.0/indexers/all/results", 
                                  params=params, timeout=30)
            
            if response.status_code == 200:
                data = response.json()
                results = data.get("Results", [])
                
                if results:
                    print(f"{Colors.GREEN}✓ Found {len(results)} results (method {i+1}){Colors.NC}")
                    
                    # Filter results to match query better
                    filtered_results = []
                    query_lower = query.lower()
                    
                    for result in results[:50]:  # Check first 50
                        title = result.get("Title", "").lower()
                        if query_lower in title:
                            filtered_results.append(result)
                    
                    if filtered_results:
                        print(f"{Colors.CYAN}Showing {min(20, len(filtered_results))} relevant results:{Colors.NC}")
                        print()
                        
                        for i, result in enumerate(filtered_results[:20], 1):
                            title = result.get("Title", "Unknown")
                            size = result.get("Size", 0)
                            seeders = result.get("Seeders", 0)
                            tracker = result.get("Tracker", "Unknown")
                            
                            # Format size
                            if size >= 1073741824:
                                size_str = f"{size/1073741824:.1f} GB"
                            elif size >= 1048576:
                                size_str = f"{size/1048576:.1f} MB"
                            else:
                                size_str = f"{size/1024:.1f} KB"
                            
                            print(f"{i:2d}. {title[:70]}")
                            print(f"    Size: {size_str:<12} Seeds: {seeders:<4} Tracker: {tracker}")
                            print()
                        
                        return filtered_results[:20]
                    else:
                        print(f"{Colors.YELLOW}Found results but none match {query} closely{Colors.NC}")
                else:
                    print(f"{Colors.YELLOW}No results found with method {i+1}{Colors.NC}")
                    
        except Exception as e:
            print(f"{Colors.RED}Search method {i+1} failed: {e}{Colors.NC}")
            continue
    
    print(f"{Colors.RED}All search methods failed. Please check Jackett configuration.{Colors.NC}")
    return []

def main():
    print(f"{Colors.GREEN}=== Fixed Torrent Search Tool ==={Colors.NC}")
    print()
    
    while True:
        query = input("Enter search query (or quit to exit): ").strip()
        if query.lower() == quit:
            break
            
        if query:
            results = search_torrents_fixed(query)
            if results:
                selection = input("\\nEnter number to view details (or Enter to search again): ").strip()
                if selection.isdigit():
                    idx = int(selection) - 1
                    if 0 <= idx < len(results):
                        result = results[idx]
                        print(f"\\n{Colors.CYAN}Selected: {result.get(Title, Unknown)}{Colors.NC}")
                        print(f"Size: {result.get(Size, 0)} bytes")
                        print(f"Tracker: {result.get(Tracker, Unknown)}")
            print()

if __name__ == "__main__":
    main()
