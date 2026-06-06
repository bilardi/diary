#!/usr/bin/env bash
set -euo pipefail

# Diary parser: reads social.yml and _posts/*.en.md, outputs posts.json.
# Requires: python3, pyyaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "$SCRIPT_DIR/parse-diary.py"
