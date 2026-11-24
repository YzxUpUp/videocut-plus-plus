"""Locate recurring corner overlays with Vision and repair tracked regions with OpenCV."""

import argparse
from collections import defaultdict
from dataclasses import dataclass
from fractions import Fraction
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile

import av
import cv2
import numpy as np
import objc
from Foundation import NSData, NSDictionary
import Quartz
import Vision


SCAN_WIDTH = 540
OVERLAY_WORDS = re.compile(r"bilibili|douyin|tiktok|watermark|抖音|哔哩哔哩|^[@＠]", re.I)


def announce(message):
    print("PROGRESS " + message, flush=True)


def scan_image(frame):
    factor = min(1, SCAN_WIDTH / max(frame.width, frame.height))
    return frame.reformat(width=round(frame.width * factor), height=round(frame.height * factor),
                          format="bgr24", interpolation="AREA").to_ndarray()


def cg_image(image):
    encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 88])[1].tobytes()
    data = NSData.dataWithBytes_length_(encoded, len(encoded))
    source = Quartz.CGImageSourceCreateWithData(data, None)
    return Quartz.CGImageSourceCreateImageAtIndex(source, 0, None)


def box_pixels(rectangle, shape):
    height, width = shape[:2]
    x = int(round(rectangle.origin.x * width))
    y = int(round((1 - rectangle.origin.y - rectangle.size.height) * height))
    return bound_box((x, y, round(rectangle.size.width * width),
                      round(rectangle.size.height * height)), shape)


def bound_box(box, shape):
    x, y, w, h = map(int, box)
    height, width = shape[:2]
    x, y = max(0, min(width, x)), max(0, min(height, y))
    return x, y, max(0, min(width - x, w)), max(0, min(height - y, h))


def edge_box(box, shape):
    x, y, w, h = box
    height, width = shape[:2]
    horizontal_edge = x < width * 0.28 or x + w > width * 0.72
    vertical_edge = y < height * 0.20 or y + h > height * 0.80
    return horizontal_edge and vertical_edge and w < width * 0.49 and h < height * 0.15 and w >= 12 and h >= 6


def ocr(image):
    with objc.autorelease_pool():
        request = Vision.VNRecognizeTextRequest.alloc().init()
        request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
        request.setRecognitionLanguages_(["zh-Hans", "en-US"])
        request.setUsesLanguageCorrection_(False)
        handler = Vision.VNImageRequestHandler.alloc().initWithCGImage_options_(
            cg_image(image), NSDictionary.dictionary())
        ok, _ = handler.performRequests_error_([request], None)
        if not ok:
            return []
        matches = []
        for observation in request.results() or []:
            candidates = observation.topCandidates_(1)
            if not candidates:
                continue
            candidate = candidates[0]
            value = str(candidate.string()).strip()
            box = box_pixels(observation.boundingBox(), image.shape)
            if candidate.confidence() >= 0.38 and edge_box(box, image.shape) and len(value) >= 3:
                matches.append((value, box))
        return matches


def features(image):
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    return cv2.subtract(gray, cv2.GaussianBlur(gray, (0, 0), 1.8), dtype=cv2.CV_32F)


def crop(image, box):
    x, y, w, h = box
    return image[y:y + h, x:x + w]


@dataclass
class Example:
    time: float
    box: tuple
    patch: np.ndarray
    background: np.ndarray
    keyword: bool = False



def matte_marks(gray):
    height, width = gray.shape
    maximum = max(8, round(height * 0.14))
    for bottom in (False, True):
        outer = gray[::-1] if bottom else gray
        length = next((i for i, row in enumerate(outer[:maximum]) if np.mean(row < 19) < 0.59), maximum)
        if length < 8:
            continue
        band = gray[height - length:] if bottom else gray[:length]
        for left, right in ((0, width // 2), (width // 2, width)):
            mark = band[:, left:right] >= 26
            rows, columns = np.where(mark)
            if len(rows) < 35 or len(rows) > mark.size * 0.28:
                continue
            x, y = int(columns.min()), int(rows.min())
            box = (left + x, (height - length if bottom else 0) + y,
                   int(columns.max()) - x + 1, int(rows.max()) - y + 1)
            if edge_box(box, gray.shape):
                yield box

def brightness_regions(gray):
    height, width = gray.shape
    for x in (0, int(width * 0.62)):
        for y in (0, int(height * 0.78)):
            w, h = int(width * 0.38), int(height * 0.22)
            region = crop(gray, (x, y, w, h))
            contrast = cv2.absdiff(region, cv2.GaussianBlur(region, (0, 0), 2.0))
            mask = (contrast > 24).astype(np.uint8)
            joined = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((3, 7), np.uint8))
            count, _, stats, _ = cv2.connectedComponentsWithStats(joined, 8)
            if count <= 1:
                continue
            for rx, ry, rw, rh, area in sorted(stats[1:], key=lambda entry: entry[4], reverse=True)[:5]:
                if rw < 15 or rh < 10 or rw > w * 0.87 or rh > min(h * 0.75, height * 0.13):
                    continue
                if area >= 75 and rx > 0 and ry > 0 and rx + rw < w and ry + rh < h:
                    yield (int(x + rx), int(y + ry), int(rw), int(rh))


def locate(feature_map, patch, around=None):
    hp, wp = patch.shape
    if hp < 4 or wp < 8 or float(patch.std()) < 2.0:
        return 0, None
    if around is not None:
        x, y, w, h = around
        margin = max(14, wp // 2, hp // 2)
        region = bound_box((x - margin, y - margin, w + 2 * margin, h + 2 * margin),
                           feature_map.shape)
    else:
        region = (0, 0, feature_map.shape[1], feature_map.shape[0])
    search = crop(feature_map, region)
    if search.shape[0] < hp or search.shape[1] < wp:
        return 0, None
    result = cv2.matchTemplate(search, patch, cv2.TM_CCOEFF_NORMED)
    _, score, _, point = cv2.minMaxLoc(result)
    return score, (point[0] + region[0], point[1] + region[1], wp, hp)


def has_motion_or_scene(examples):
    for a, b in zip(examples, examples[1:]):
        if abs(a.box[0] - b.box[0]) + abs(a.box[1] - b.box[1]) > 16:
            return True
        if np.mean(cv2.absdiff(a.background, b.background)) > 18:
            return True
    return False


def media_frames(path):
    with av.open(path) as container:
        stream = next((s for s in container.streams.video if not (s.disposition.value & 0x400)), None)
        if stream is None:
            raise ValueError("没有视频轨")
        stream.thread_type = "AUTO"
        origin = Fraction(container.start_time or 0, av.time_base)
        duration = float(container.duration or 0) / av.time_base
        for frame in container.decode(stream):
            if frame.pts is not None:
                yield frame, Fraction(frame.pts) * frame.time_base - origin, stream, duration


def manual_box(seed, shape):
    height, width = shape[:2]
    return bound_box((round(seed["x"] * width), round(seed["y"] * height),
                      round(seed["width"] * width), round(seed["height"] * height)), shape)


def scan(source, seeds):
    recent = defaultdict(list)
    graphic_samples = []
    manual = []
    manual_index = 0
    next_sample = 0.0
    scanned = 0
    for frame, exact, _, duration in media_frames(source):
        time = float(exact)
        manual_due = manual_index < len(seeds) and seeds[manual_index]["seconds"] <= time + 0.015
        if time < next_sample and not manual_due:
            continue
        with objc.autorelease_pool():
            image = scan_image(frame)
            signal = features(image)
            gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
            center = gray[gray.shape[0] // 4:gray.shape[0] * 3 // 4,
                          gray.shape[1] // 4:gray.shape[1] * 3 // 4]
            background = cv2.resize(center, (18, 12), interpolation=cv2.INTER_AREA)
            while manual_index < len(seeds) and seeds[manual_index]["seconds"] <= time + 0.015:
                box = manual_box(seeds[manual_index], image.shape)
                if box[2] >= 8 and box[3] >= 4:
                    manual.append(Example(time, box, crop(signal, box).copy(), background))
                manual_index += 1
            if time >= next_sample:
                for text, box in ocr(image):
                    key = "".join(character.lower() for character in text if character.isalnum())
                    if len(key) >= 3:
                        sample = Example(time, box, crop(signal, box).copy(), background, bool(OVERLAY_WORDS.search(text)))
                        recent[key].append(sample)
                if len(graphic_samples) < 16 and (not graphic_samples or time - graphic_samples[-1][0] >= max(1, duration / 16)):
                    graphic_samples.append((time, signal, background, list(matte_marks(gray)) + list(brightness_regions(gray))))
                scanned += 1
                if scanned % 5 == 1:
                    announce(f"检测水印 {min(99, int(time / max(1, duration) * 100))}%")
                next_sample = time + 0.78
    if seeds and not manual:
        raise ValueError("水印框太小或超出画面，请调整后重试")
    graphic = find_graphic(graphic_samples) if not manual else []
    tracked = [manual] if manual else ([graphic] if graphic else [])
    ranked = sorted(recent.values(), key=lambda samples: (
        any(item.keyword for item in samples), len(samples)), reverse=True)
    for samples in ranked:
        count = len({item.time for item in samples})
        recognized = any(item.keyword for item in samples)
        minimum = max(3, math.ceil(scanned * 0.04)) if recognized else max(4, math.ceil(scanned * 0.18))
        if count < minimum or (not recognized and not has_motion_or_scene(samples)):
            continue
        if tracked and any(matches_same_overlay(samples[0], group) for group in tracked):
            continue
        step = max(1, len(samples) // 12)
        tracked.append(samples[::step][:12])
        if len(tracked) >= 3:
            break
    return tracked


def matches_same_overlay(example, group):
    x, y, w, h = example.box
    for item in group[:12]:
        other_x, other_y, other_w, other_h = item.box
        if abs(example.time - item.time) > 1.7:
            continue
        intersection_w = max(0, min(x + w, other_x + other_w) - max(x, other_x))
        intersection_h = max(0, min(y + h, other_y + other_h) - max(y, other_y))
        if intersection_w * intersection_h > 0.35 * min(w * h, other_w * other_h):
            return True
    return False


def find_graphic(samples):
    if len(samples) < 4:
        return []
    best = []
    for time, image, background, boxes in samples[:4]:
        for box in boxes:
            patch = crop(image, box).copy()
            matches = [Example(time, box, patch, background)]
            for later_time, later, later_background, _ in samples:
                if later_time == time:
                    continue
                score, found = locate(later, patch)
                if found is not None and score >= 0.73 and edge_box(found, later.shape):
                    matches.append(Example(later_time, found, patch, later_background))
            matches.sort(key=lambda item: item.time)
            if len(matches) >= max(4, math.ceil(len(samples) * 0.5)) and len(matches) > len(best) and has_motion_or_scene(matches):
                best = matches
    return best[:12]


class Tracker:
    def __init__(self, examples):
        self.examples = examples
        self.last = None
        self.request = None
        self.sequence = None
        self.last_vision_time = -1.0

    def locate(self, feature_map, image, time):
        nearby = sorted(self.examples, key=lambda item: abs(item.time - time))[:3]
        if self.last is not None:
            score, found = self.best(feature_map, nearby, self.last)
            if score >= 0.67:
                self.last = found
                if time - self.last_vision_time >= 0.4:
                    self._refresh_vision(image, found, time)
                return found
        score, found = self.best(feature_map, nearby, None)
        if score >= 0.65:
            self.last = found
            self._refresh_vision(image, found, time)
            return found
        candidate = next((item for item in nearby if abs(item.time - time) <= 0.035), None)
        if candidate is not None:
            self.last = candidate.box
            self._refresh_vision(image, candidate.box, time)
            return candidate.box
        if self.request is not None:
            found = self._vision(image)
            if found is not None:
                score, verified = self.best(feature_map, nearby, found)
                if score >= 0.52 and self.close(verified, found):
                    self.last = verified
                    return verified
        self.request = None
        self.sequence = None
        self.last = None
        return None

    @staticmethod
    def best(image, examples, around):
        return max((locate(image, item.patch, around) for item in examples), key=lambda item: item[0])

    @staticmethod
    def close(a, b):
        return a is not None and abs(a[0] - b[0]) + abs(a[1] - b[1]) <= max(8, b[2] // 5)

    def _refresh_vision(self, image, box, time):
        self.last_vision_time = time
        x, y, w, h = box
        height, width = image.shape[:2]
        rectangle = ((x / width, 1 - (y + h) / height), (w / width, h / height))
        observation = Vision.VNDetectedObjectObservation.observationWithBoundingBox_(rectangle)
        if self.request is None:
            self.sequence = Vision.VNSequenceRequestHandler.alloc().init()
            self.request = Vision.VNTrackObjectRequest.alloc().initWithDetectedObjectObservation_(observation)
            self.request.setTrackingLevel_(Vision.VNRequestTrackingLevelFast)
        self.request.setInputObservation_(observation)
        self.sequence.performRequests_onCGImage_error_([self.request], cg_image(image), None)
        self.request.setInputObservation_(observation)

    def _vision(self, image):
        ok, _ = self.sequence.performRequests_onCGImage_error_([self.request], cg_image(image), None)
        results = self.request.results() if ok else None
        if results and results[0].confidence() >= 0.45:
            self.request.setInputObservation_(results[0])
            return box_pixels(results[0].boundingBox(), image.shape)
        return None


def repair_frame(original, small_shape, boxes, width, height):
    source = original.reformat(format="yuv420p")
    if not boxes and (source.width, source.height) == (width, height):
        return source
    edited = av.VideoFrame(width, height, "yuv420p")
    scale_x, scale_y = original.width / small_shape[1], original.height / small_shape[0]
    for in_plane, out_plane in zip(source.planes, edited.planes):
        src = np.frombuffer(in_plane, dtype=np.uint8).reshape(in_plane.height, in_plane.line_size)[:, :in_plane.width]
        dst = np.frombuffer(out_plane, dtype=np.uint8).reshape(out_plane.height, out_plane.line_size)[:, :out_plane.width]
        dst[:in_plane.height, :in_plane.width] = src
        if out_plane.width > in_plane.width:
            dst[:in_plane.height, in_plane.width:] = src[:, -1:]
        if out_plane.height > in_plane.height:
            dst[in_plane.height:, :] = dst[in_plane.height - 1, :]
        step = 1 if in_plane.width == original.width else 2
        for x, y, w, h in boxes:
            left = max(0, math.floor((x - 2) * scale_x / step))
            top = max(0, math.floor((y - 2) * scale_y / step))
            right = min(out_plane.width, math.ceil((x + w + 2) * scale_x / step))
            bottom = min(out_plane.height, math.ceil((y + h + 2) * scale_y / step))
            margin = 10
            crop_x, crop_y = max(0, left - margin), max(0, top - margin)
            region = dst[crop_y:min(out_plane.height, bottom + margin),
                         crop_x:min(out_plane.width, right + margin)]
            mask = np.zeros(region.shape, dtype=np.uint8)
            mask[top - crop_y:bottom - crop_y, left - crop_x:right - crop_x] = 255
            region[:] = cv2.inpaint(region, mask, 4 if step == 1 else 2, cv2.INPAINT_TELEA)
    return edited


def write_repaired(source, output, example_groups, ffmpeg):
    trackers = [Tracker(group) for group in example_groups]
    count = 0
    uncertain = []
    interval_start = None
    next_progress = 0
    last_time = 0
    with tempfile.TemporaryDirectory(prefix=".repair-", dir=output.parent) as tmp:
        video_only = str(Path(tmp) / "video.mp4")
        with av.open(video_only, "w") as container:
            encoder = None
            for frame, exact, stream, duration in media_frames(source):
                time = max(0, float(exact))
                last_time = time
                if encoder is None:
                    encoder = container.add_stream("libx264", rate=stream.average_rate or 30,
                                                   options={"preset": "veryfast", "crf": "17", "bf": "0"})
                    encoder.width = (frame.width + 1) // 2 * 2
                    encoder.height = (frame.height + 1) // 2 * 2
                    encoder.pix_fmt = "yuv420p"
                    encoder.codec_context.time_base = Fraction(1, 60000)
                    for attribute in ("color_range", "colorspace", "color_primaries", "color_trc"):
                        if hasattr(stream.codec_context, attribute) and hasattr(encoder.codec_context, attribute):
                            setattr(encoder.codec_context, attribute, getattr(stream.codec_context, attribute))
                with objc.autorelease_pool():
                    small = scan_image(frame)
                    signal = features(small)
                    found = [box for tracker in trackers if (box := tracker.locate(signal, small, time)) is not None]
                if found:
                    count += 1
                missing = len(found) < len(trackers)
                if missing and interval_start is None:
                    interval_start = time
                elif not missing and interval_start is not None:
                    if time - interval_start >= 0.15:
                        uncertain.append({"start": interval_start, "end": time})
                    interval_start = None
                edited = repair_frame(frame, small.shape, found, encoder.width, encoder.height)
                edited.pts = max(0, round(exact * 60000))
                edited.time_base = Fraction(1, 60000)
                for packet in encoder.encode(edited):
                    container.mux(packet)
                if time >= next_progress:
                    announce(f"修补水印 {min(99, int(time / max(1, duration) * 100))}%")
                    next_progress = time + 1
            if encoder is None:
                raise ValueError("视频没有可解码画面")
            for packet in encoder.encode():
                container.mux(packet)
        if interval_start is not None and last_time - interval_start >= 0.15:
            uncertain.append({"start": interval_start, "end": last_time})
        if count:
            subprocess.run([
                ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                "-i", video_only, "-i", str(source), "-map", "0:v:0", "-map", "1:a:0?",
                "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(output)
            ], check=True)
    return count, uncertain


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("seeds", type=Path)
    parser.add_argument("ffmpeg")
    args = parser.parse_args()
    seeds = sorted(json.loads(args.seeds.read_text()), key=lambda item: item["seconds"])
    cv2.setNumThreads(min(4, os.cpu_count() or 1))
    groups = scan(args.source, seeds)
    count, uncertain = write_repaired(args.source, args.output, groups, args.ffmpeg) if groups else (0, [])
    args.report.write_text(json.dumps({
        "detected": len(groups), "repairedFrames": count, "uncertain": uncertain
    }))


if __name__ == "__main__":
    main()
