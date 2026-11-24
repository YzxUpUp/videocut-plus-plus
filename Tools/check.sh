#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -o .build/videocut-check \
  Sources/VideoCut/{Domain,ProcessTools,Media,AI,DownloadCleanup}.swift Tools/check.swift
.build/videocut-check
