"""Exercise automatic fixed and moving watermark removal on generated footage."""

from fractions import Fraction
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import av
import cv2
import numpy as np


WIDTH, HEIGHT, FPS, FRAMES = 640, 360, 20, 160
TEXT = "@WATERMARK"
CAPTION = "Normal subtitle"


def location(index, mode):
    if mode == "fixed" or index < 36:
        return 32, 37
    if index < 82:
        return 32 + 2 * (index - 36), 37 + (index - 36) // 4
    if index < 121:
        return 438, 43
    return 416, 330


def make_fixture(path, mode):
    with av.open(str(path), "w") as file:
        stream = file.add_stream("libx264", rate=FPS, options={"crf": "16"})
        stream.width, stream.height = WIDTH, HEIGHT
        stream.pix_fmt = "yuv420p"
        for index in range(FRAMES):
            colors = [(74, 57, 40), (47, 89, 109), (92, 73, 118), (58, 104, 62)]
            image = np.full((HEIGHT, WIDTH, 3), colors[index // 40], np.uint8)
            cv2.circle(image, (190 + index % 140, 175), 63, (129, 50, 145), -1)
            cv2.putText(image, CAPTION, (213, 296), cv2.FONT_HERSHEY_SIMPLEX, .6, (238, 236, 234), 2)
            if mode != "clean":
                cv2.putText(image, TEXT, location(index, mode), cv2.FONT_HERSHEY_SIMPLEX,
                            .78, (250, 250, 250), 2, cv2.LINE_AA)
            frame = av.VideoFrame.from_ndarray(image, format="bgr24")
            frame.pts, frame.time_base = index, Fraction(1, FPS)
            for packet in stream.encode(frame):
                file.mux(packet)
        for packet in stream.encode():
            file.mux(packet)


def frames(path):
    with av.open(str(path)) as file:
        for frame in file.decode(video=0):
            yield frame.to_ndarray(format="bgr24")


def check_pixels(before, after, mode):
    frame_count = 0
    repaired = 0
    for index, (source, output) in enumerate(zip(frames(before), frames(after))):
        frame_count += 1
        x, y = location(index, mode)
        source_logo = source[y - 24:y + 9, x:x + 176]
        output_logo = output[y - 24:y + 9, x:x + 176]
        logo_pixels = (source_logo.min(axis=2) > 210)
        assert logo_pixels.any()
        if np.mean(output_logo[logo_pixels].min(axis=1) < 165) > .92:
            repaired += 1
        subtitle = source[275:300, 210:410]
        subtitle_output = output[275:300, 210:410]
        assert np.mean(cv2.absdiff(subtitle, subtitle_output)) < 3, f"{mode}: subtitle altered"
    assert len(list(frames(after))) == frame_count == FRAMES
    assert repaired >= FRAMES * .97, f"{mode}: watermark remains in {FRAMES - repaired} frames"
    return repaired


def main():
    script = Path(__file__).with_name("watermark.py").resolve()
    with tempfile.TemporaryDirectory(prefix="videocut-watermark-check-") as directory:
        root = Path(directory)
        seed = root / "seeds.json"
        seed.write_text("[]")
        for mode in ("fixed", "moving", "clean"):
            source = root / (mode + ".mp4")
            output = root / (mode + "-output.mp4")
            report_path = root / (mode + ".json")
            make_fixture(source, mode)
            result = subprocess.run(
                [sys.executable, str(script), str(source), str(output), str(report_path), str(seed), "/opt/homebrew/bin/ffmpeg"],
                capture_output=True, text=True,
            )
            assert not result.returncode, result.stderr
            report = json.loads(report_path.read_text())
            if mode == "clean":
                assert report["detected"] == report["repairedFrames"] == 0
                assert not output.exists()
                print("无水印样片未被修改")
            else:
                assert report["detected"] > 0, f"{mode}: {report}"
                print(f"{mode}: {check_pixels(source, output, mode)}/{FRAMES} 帧水印修补，字幕保留", flush=True)


if __name__ == "__main__":
    main()
