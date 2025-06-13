#\!/usr/bin/env python3
import requests
import json

# Test magnet download directly
TRANSMISSION_URL = 'http://192.168.2.2:9091/transmission/rpc'
TRANSMISSION_USER = 'admin'
TRANSMISSION_PASS = 'invent-creat3'

# Test magnet link from Rick and Morty search
magnet_link = 'magnet:?xt=urn:btih:96e27060c265a505ef722dc9405c32b211f3b5a9&dn=rick.and.morty.s08e01.1080p.web.h264-lazycunts%5BEZTVx.to%5D.mkv%5Beztvx.to%5D&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce'

def get_session():
    try:
        response = requests.get(
            TRANSMISSION_URL,
            auth=(TRANSMISSION_USER, TRANSMISSION_PASS),
            timeout=10
        )
        return response.headers.get('X-Transmission-Session-Id')
    except Exception as e:
        print(f'Session error: {e}')
        return None

session_id = get_session()
if not session_id:
    print('Could not get session ID')
    exit(1)

print(f'Got session ID: {session_id}')

# Test magnet download
headers = {
    'X-Transmission-Session-Id': session_id,
    'Content-Type': 'application/json'
}

request_data = {
    'method': 'torrent-add',
    'arguments': {
        'filename': magnet_link
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
    
    print(f'Response: {json.dumps(result, indent=2)}')
    
    if result.get('result') == 'success':
        print('SUCCESS: Magnet link added to Transmission\!')
    else:
        print(f'FAILED: {result.get("result", "Unknown error")}')
        
except Exception as e:
    print(f'ERROR: {e}')
