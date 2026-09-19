#!/usr/bin/env python3
import os
import sys

def main():
    if len(sys.argv) < 2:
        sys.exit(1)
        
    token_path = sys.argv[1]
    token = os.environ.get("CIDER_TOKEN", "").strip()
    
    if not token:
        sys.exit(1)
        
    os.makedirs(os.path.dirname(token_path), exist_ok=True)
    
    # Save with 0600 permissions
    fd = os.open(token_path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(token)

if __name__ == "__main__":
    main()
