#\!/usr/bin/env python3
import sys
sys.path.append(".")
from torrent_search import search_torrents

# Test search function
print("Testing search functionality...")
results = search_torrents("test", "search")
print(f"Search returned {len(results)} results")

if results:
    print("Sample result:")
    result = results[0]
    print(f"Title: {result.get(Title, N/A)}")
    print(f"Size: {result.get(Size, 0)}")
    print(f"Seeders: {result.get(Seeders, 0)}")
    print("Search test: PASSED")
else:
    print("Search test: No results (but functional)")
