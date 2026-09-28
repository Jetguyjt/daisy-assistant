#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BROWSER_DIR="$HOME/Library/Application Support/Daisy/Runtime/browser"
mkdir -p "$BROWSER_DIR"
cp "$REPO_DIR/scripts/browser/package.json" "$BROWSER_DIR/package.json"
cp "$REPO_DIR/scripts/browser/package-lock.json" "$BROWSER_DIR/package-lock.json"
CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1 CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1 npm ci --prefix "$BROWSER_DIR" --ignore-scripts --no-audit --no-fund
echo "Chrome connector installed. Connecting to your signed-in Chrome still requires your approval in Chrome."
