#\!/bin/bash

echo "=== JACKETT SERVICE FIX ==="
echo "Date: $(date)"
echo ""

# Root Cause: Jackett container is running but the Jackett service inside is not starting
# This is indicated by s6 supervisor running but no actual Jackett process

echo "=== Step 1: Remove Problematic Configuration ==="
# The RUN_OPTS with proxy connection may be causing issues
cp docker-compose.yml docker-compose.yml.backup3

# Remove the problematic RUN_OPTS proxy configuration
sed -i /RUN_OPTS=--ProxyConnection/d docker-compose.yml

echo "=== Step 2: Fix Healthcheck URL ==="
# Change healthcheck to simple root path instead of /UI/Login
sed -i s
