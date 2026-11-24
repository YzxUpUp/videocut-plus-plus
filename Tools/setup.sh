#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOMEBREW_NO_AUTO_UPDATE=1
support_dir="$HOME/Library/Application Support/VideoCut++"
mkdir -p "$support_dir/Models"

if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null ||
   ! command -v yt-dlp >/dev/null || ! command -v deno >/dev/null ||
   ! command -v whisper-cli >/dev/null; then
  if ! command -v brew >/dev/null; then
    echo 'Error: 请先从 https://brew.sh/ 安装 Homebrew，再重试。'
    exit 1
  fi
  brew install ffmpeg yt-dlp deno whisper.cpp
fi

venv_dir="$support_dir/venv"
if [[ ! -x "$venv_dir/bin/python" ]]; then
  /usr/bin/python3 -m venv "$venv_dir"
fi
if [[ ! -f "$venv_dir/.watermark-ready" ]]; then
  echo '安装 OpenCV 和 Vision 组件'
  "$venv_dir/bin/python" -m pip install --disable-pip-version-check --only-binary=:all: \
    'numpy==1.26.4' 'opencv-python-headless==4.11.0.86' 'av==14.2.0' \
    'pyobjc-core==11.1' 'pyobjc-framework-Cocoa==11.1' 'pyobjc-framework-CoreML==11.1' \
    'pyobjc-framework-Vision==11.1' 'pyobjc-framework-Quartz==11.1'
  "$venv_dir/bin/python" -c 'import av, cv2, Vision, Quartz'
  touch "$venv_dir/.watermark-ready"
fi

model_file="$support_dir/Models/ggml-base.bin"
checksum='60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe'
if [[ ! -r "$model_file" ]]; then
  echo '下载 Whisper 多语言模型（约 142 MiB）'
  partial="$model_file.part"
  trap 'rm -f "$partial"' EXIT
  curl --fail --silent --show-error --location --retry 2 \
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin' -o "$partial"
  printf '%s  %s\n' "$checksum" "$partial" | shasum -a 256 -c -
  mv "$partial" "$model_file"
fi
echo '依赖已就绪'
