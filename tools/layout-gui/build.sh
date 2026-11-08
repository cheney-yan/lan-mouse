#!/bin/sh
# Builds the two tiny CoreGraphics helpers used by server.py (macOS only).
set -e
cd "$(dirname "$0")"
swiftc -O displays.swift -o displays
swiftc -O arrange.swift -o arrange
echo "built: displays, arrange"
