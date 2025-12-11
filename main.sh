#!/bin/bash
set -euo pipefail
echo "Hello from repo main.sh — starting a simple HTTP server on port 3000"
# serve current directory on port 3000 (keeps container alive)
python3 -m http.server 3000
