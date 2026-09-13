#!/bin/bash
date >> /tmp/fetch_metadata_debug.log

# Fetch play state via playerctl
STATUS=$(playerctl status 2>/dev/null)

# Fetch rich metadata
# Read token dynamically
TOKEN_FILE="$(dirname "$0")/cider_token.txt"
if [ -f "$TOKEN_FILE" ]; then
    TOKEN=$(cat "$TOKEN_FILE")
else
    TOKEN=""
fi

# 1. Intentar obtener metadata desde la API de Cider usando el Token
if [ -n "$TOKEN" ]; then
    JSON=$(curl -s --max-time 1 -H "apptoken: $TOKEN" http://127.0.0.1:10767/api/v1/playback/now-playing 2>/dev/null)
else
    JSON=""
fi

if [ -z "$JSON" ] || echo "$JSON" | grep -q "UNAUTHORIZED_APP_TOKEN"; then
    # Fallback to pure MPRIS
    TITLE=$(playerctl metadata title 2>/dev/null)
    ARTIST=$(playerctl metadata artist 2>/dev/null)
    ARTURL=$(playerctl metadata mpris:artUrl 2>/dev/null)
    POS=$(playerctl position 2>/dev/null)
    LEN_MICRO=$(playerctl metadata mpris:length 2>/dev/null)
    
    if [ -n "$LEN_MICRO" ] && [ "$LEN_MICRO" != "0" ]; then
        LEN=$(awk "BEGIN {print $LEN_MICRO / 1000000}")
    else
        LEN=0
    fi
else
    # Parse API JSON with jq
    TITLE=$(echo "$JSON" | jq -r '.info.name // ""')
    ARTIST=$(echo "$JSON" | jq -r '.info.artistName // ""')
    ARTURL=$(echo "$JSON" | jq -r '.info.artwork.url // ""')
    POS=$(echo "$JSON" | jq -r '.info.currentPlaybackTime // "0"')
    
    # URL might be different sizes, we just take the default
    
    LEN_MILLI=$(echo "$JSON" | jq -r '.info.durationInMillis // "0"')
    if [ -n "$LEN_MILLI" ] && [ "$LEN_MILLI" != "0" ]; then
        LEN=$(awk "BEGIN {print $LEN_MILLI / 1000}")
    else
        LEN=0
    fi
fi

# Output string separated by |||
echo -n "${STATUS}|||${TITLE}|||${ARTIST}|||${ARTURL}|||${POS}|||${LEN}"
