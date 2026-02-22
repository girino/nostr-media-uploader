#!/usr/bin/env python3
"""
Classify image or video files as SFW (safe for work) or NSFW.
Backends: NudeNet (body-part detection) or Falconsai (Hugging Face ViT model).
Outputs JSON: list of {filename, nsfw, safe, unsafe, top_class} per file.
"""
import argparse
import json
import sys
from pathlib import Path

# File type detection by extension
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}
VIDEO_EXTENSIONS = {".mp4", ".avi", ".mkv", ".mov", ".webm", ".wmv", ".flv", ".m4v"}

# Sensitivity: low = exposed only (nudity); high = exposed + extra (belly, feet, armpits exposed)
NSFW_EXPOSED = {
    "FEMALE_GENITALIA_EXPOSED",
    "MALE_GENITALIA_EXPOSED",
    "FEMALE_BREAST_EXPOSED",
    "BUTTOCKS_EXPOSED",
    "ANUS_EXPOSED",
}
NSFW_EXTRA = {
    "BELLY_EXPOSED",
    "MALE_BREAST_EXPOSED",
    "FEMALE_GENITALIA_COVERED",
    "ANUS_COVERED",
    # "FEMALE_BREAST_COVERED",
    # "ARMPITS_EXPOSED",
    # "FEET_EXPOSED",
    # "BELLY_COVERED",
    # "FEET_COVERED",
    # "BUTTOCKS_COVERED",
    # "ARMPITS_COVERED",
    # "FACE_FEMALE",
    # "FACE_MALE",
}
SENSITIVITY_CLASSES = {
    "low": NSFW_EXPOSED,
    "high": NSFW_EXPOSED | NSFW_EXTRA,
}


def get_file_type(path: Path) -> str:
    """Return 'image', 'video', or raise ValueError."""
    ext = path.suffix.lower()
    if ext in IMAGE_EXTENSIONS:
        return "image"
    if ext in VIDEO_EXTENSIONS:
        return "video"
    raise ValueError(f"Unknown file type for extension {ext!r}. Supported: image {sorted(IMAGE_EXTENSIONS)}, video {sorted(VIDEO_EXTENSIONS)}")


def unsafe_score_and_class_from_detections(detections: list, nsfw_classes: set) -> tuple[float, str | None]:
    """Return (max_score, top_class_name) among detections in nsfw_classes, or (0.0, None) if none."""
    if not detections:
        return 0.0, None
    matching = [(d["score"], d["class"]) for d in detections if d.get("class") in nsfw_classes]
    if not matching:
        return 0.0, None
    return max(matching, key=lambda x: x[0])


def classify_one_nudenet(detector, path: Path, args, nsfw_classes: set) -> dict:
    """Classify one file with NudeNet; return {filename, nsfw, safe, unsafe, top_class} or {filename, error}."""
    path = path.resolve()
    filename = path.name
    if not path.is_file():
        return {"filename": filename, "error": f"not a file: {path}"}
    try:
        file_type = get_file_type(path)
    except ValueError as e:
        return {"filename": filename, "error": str(e)}

    path_str = str(path)

    if file_type == "image":
        detections = detector.detect(path_str)
        unsafe, top_class = unsafe_score_and_class_from_detections(detections, nsfw_classes)
    else:
        import cv2
        cap = cv2.VideoCapture(path_str)
        if not cap.isOpened():
            return {"filename": filename, "error": f"could not open video: {path}"}
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) or 1
        num_samples = args.video_frames
        if total_frames <= num_samples:
            frame_indices = list(range(total_frames))
        else:
            frame_indices = [int(round(i * (total_frames - 1) / (num_samples - 1))) for i in range(num_samples)]
        frames = []
        try:
            for idx in frame_indices:
                cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
                ret, frame = cap.read()
                if ret:
                    frames.append(frame)
        finally:
            cap.release()
        unsafe = 0.0
        top_class = None
        if frames:
            for dets in detector.detect_batch(frames):
                s, c = unsafe_score_and_class_from_detections(dets, nsfw_classes)
                if s > unsafe:
                    unsafe, top_class = s, c
    safe = round(1.0 - unsafe, 3)
    unsafe = round(unsafe, 3)
    is_nsfw = unsafe > args.threshold
    return {"filename": filename, "nsfw": is_nsfw, "safe": safe, "unsafe": unsafe, "top_class": top_class}


def classify_one_falconsai(pipeline, path: Path, args) -> dict:
    """Classify one file with Falconsai (Hugging Face); return same shape as NudeNet."""
    from PIL import Image

    path = path.resolve()
    filename = path.name
    if not path.is_file():
        return {"filename": filename, "error": f"not a file: {path}"}
    try:
        file_type = get_file_type(path)
    except ValueError as e:
        return {"filename": filename, "error": str(e)}

    path_str = str(path)

    if file_type == "image":
        img = Image.open(path_str).convert("RGB")
        preds = pipeline(img)
        # preds e.g. [{"label": "nsfw", "score": 0.9}, {"label": "normal", "score": 0.1}]
        nsfw_score = 0.0
        for p in preds:
            if p.get("label", "").lower() == "nsfw":
                nsfw_score = p.get("score", 0.0)
                break
        unsafe = round(nsfw_score, 3)
        safe = round(1.0 - unsafe, 3)
        is_nsfw = unsafe > args.threshold
        top_class = "nsfw" if is_nsfw else None
        return {"filename": filename, "nsfw": is_nsfw, "safe": safe, "unsafe": unsafe, "top_class": top_class}
    else:
        import cv2
        cap = cv2.VideoCapture(path_str)
        if not cap.isOpened():
            return {"filename": filename, "error": f"could not open video: {path}"}
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) or 1
        num_samples = args.video_frames
        if total_frames <= num_samples:
            frame_indices = list(range(total_frames))
        else:
            frame_indices = [int(round(i * (total_frames - 1) / (num_samples - 1))) for i in range(num_samples)]
        unsafe = 0.0
        try:
            for idx in frame_indices:
                cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
                ret, frame = cap.read()
                if not ret:
                    continue
                # BGR -> RGB, numpy -> PIL
                import numpy as np
                frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                pil_img = Image.fromarray(frame_rgb)
                preds = pipeline(pil_img)
                for p in preds:
                    if p.get("label", "").lower() == "nsfw":
                        if p.get("score", 0.0) > unsafe:
                            unsafe = p.get("score", 0.0)
                        break
        finally:
            cap.release()
        unsafe = round(unsafe, 3)
        safe = round(1.0 - unsafe, 3)
        is_nsfw = unsafe > args.threshold
        top_class = "nsfw" if is_nsfw else None
        return {"filename": filename, "nsfw": is_nsfw, "safe": safe, "unsafe": unsafe, "top_class": top_class}


def main() -> int:
    parser = argparse.ArgumentParser(description="Classify images/videos as SFW/NSFW using NudeNet. Outputs JSON.")
    parser.add_argument("path", type=Path, nargs="+", help="Path(s) to image or video file(s)")
    parser.add_argument("--threshold", type=float, default=0.5, help="Unsafe score threshold (default: 0.5)")
    parser.add_argument("--batch-size", type=int, default=4, help="Batch size for video (default: 4)")
    parser.add_argument("--video-frames", type=int, default=20, help="Number of frames to sample from video (default: 20)")
    parser.add_argument(
        "--sensitivity",
        choices=["low", "high"],
        default="high",
        help="low=exposed only (nudity); high=exposed+belly/feet/armpits (default: high)",
    )
    parser.add_argument("--full-results", action="store_true", help="Include per-file results list; otherwise only global nsfw status")
    parser.add_argument(
        "--backend",
        choices=["nudenet", "falconsai"],
        default="nudenet",
        help="Backend: nudenet (body-part detection) or falconsai (Hugging Face ViT model, Falconsai/nsfw_image_detection)",
    )
    args = parser.parse_args()

    results = []
    any_nsfw = False
    errors = []

    if args.backend == "nudenet":
        try:
            from nudenet import NudeDetector
        except ImportError as e:
            print(f"Error: failed to import nudenet: {e}", file=sys.stderr)
            print(f"Python used: {sys.executable!s}", file=sys.stderr)
            return 2
        nsfw_classes = SENSITIVITY_CLASSES[args.sensitivity]
        detector = NudeDetector()
        for p in args.path:
            r = classify_one_nudenet(detector, p, args, nsfw_classes)
            results.append(r)
            if "error" in r:
                errors.append(f"{r['filename']}: {r['error']}")
            elif r.get("nsfw"):
                any_nsfw = True
    else:
        # falconsai
        try:
            from transformers import pipeline
        except ImportError as e:
            print(f"Error: failed to import transformers (required for falconsai): {e}", file=sys.stderr)
            print(f"Python used: {sys.executable!s}", file=sys.stderr)
            return 2
        classifier = pipeline("image-classification", model="Falconsai/nsfw_image_detection")
        for p in args.path:
            r = classify_one_falconsai(classifier, p, args)
            results.append(r)
            if "error" in r:
                errors.append(f"{r['filename']}: {r['error']}")
            elif r.get("nsfw"):
                any_nsfw = True

    success = len(errors) == 0
    out = {"success": success, "nsfw": any_nsfw}
    if not success:
        out["msg"] = "; ".join(errors)
    if args.full_results:
        out["results"] = results
    print(json.dumps(out, indent=2))
    return 0 if success else 2


if __name__ == "__main__":
    sys.exit(main())
