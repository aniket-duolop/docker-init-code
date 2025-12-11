#!/bin/bash
set -euo pipefail
pwd
ls
cd /
ls
python3 -m http.server 3000
