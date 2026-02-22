#!/usr/bin/env python3
"""
Classify image or video files as SFW (safe for work) or NSFW.
Backends: NudeNet, Falconsai (Hugging Face ViT), OpenAI omni-moderation-latest, Sightengine nudity-2.1.
Outputs JSON: list of {filename, nsfw, safe, unsafe, top_class} per file.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# Sightengine nudity-2.1: all classes and subclasses. Disable by setting to None (like commenting out in NudeNet).
# Only non-None entries count toward unsafe and top_class. Enable by replacing None with the string.
SIGHTENGINE_NSFW_CLASSES = [
    # ---- Intensity (7) ----
    "sexual_activity",
    "sexual_display",
    "erotica",
    "very_suggestive",
    "suggestive",
    None,  # "mildly_suggestive",
    None,  # "none",
    # ---- Suggestive classes ----
    "suggestive_classes.visibly_undressed",
    "suggestive_classes.sextoy",
    "suggestive_classes.suggestive_focus",
    "suggestive_classes.suggestive_pose",
    "suggestive_classes.lingerie",
    "suggestive_classes.male_underwear",
    None,  # "suggestive_classes.cleavage",
    "suggestive_classes.cleavage_categories.very_revealing",
    "suggestive_classes.cleavage_categories.revealing",
    None,  # "suggestive_classes.cleavage_categories.none",
    None,  # "suggestive_classes.male_chest",
    "suggestive_classes.male_chest_categories.very_revealing",
    "suggestive_classes.male_chest_categories.revealing",
    None,  # "suggestive_classes.male_chest_categories.slightly_revealing",
    None,  # "suggestive_classes.male_chest_categories.none",
    "suggestive_classes.nudity_art",
    None,  # "suggestive_classes.schematic",
    "suggestive_classes.bikini",
    "suggestive_classes.swimwear_one_piece",
    "suggestive_classes.swimwear_male",
    None,  # "suggestive_classes.minishort",
    None,  # "suggestive_classes.miniskirt",
    None,  # "suggestive_classes.other",
    # ---- Context (3) ----
    None,  # "context.sea_lake_pool",
    None,  # "context.outdoor_other",
    None,  # "context.indoor_other",
]
SIGHTENGINE_NSFW_CLASSES_ENABLED = {c for c in SIGHTENGINE_NSFW_CLASSES if c is not None}

# Ordered list for top_class (most explicit first); only used when picking top_class among enabled
SIGHTENGINE_INTENSITY_ORDER = [
    "sexual_activity",
    "sexual_display",
    "erotica",
    "very_suggestive",
    "suggestive",
    "mildly_suggestive",
    "none",
]
SIGHTENGINE_IMAGE_URL = "https://api.sightengine.com/1.0/check.json"
SIGHTENGINE_VIDEO_SYNC_URL = "https://api.sightengine.com/1.0/video/check-sync.json"

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
        top_class = "FALCONSAI"
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
        top_class = "FALCONSAI"
        return {"filename": filename, "nsfw": is_nsfw, "safe": safe, "unsafe": unsafe, "top_class": top_class}


# Max dimension for OpenAI moderation (large images can fail with 429)
OPENAI_IMAGE_MAX_PX = 1024
OPENAI_IMAGE_JPEG_QUALITY = 75  # minimum recommended for acceptable quality / smaller payload


def _openai_prepare_image(pil_image) -> str:
    """Resize to max 1024px, strip EXIF, compress as JPEG; return base64."""
    import io

    from PIL import Image

    img = pil_image.convert("RGB")
    w, h = img.size
    if w > OPENAI_IMAGE_MAX_PX or h > OPENAI_IMAGE_MAX_PX:
        ratio = min(OPENAI_IMAGE_MAX_PX / w, OPENAI_IMAGE_MAX_PX / h)
        new_size = (int(w * ratio), int(h * ratio))
        img = img.resize(new_size, Image.Resampling.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=OPENAI_IMAGE_JPEG_QUALITY)
    buf.seek(0)
    return base64.standard_b64encode(buf.read()).decode("ascii")


def _openai_image_input(path: Path) -> dict:
    """Read image, resize/strip/compress, return { type: image_url, image_url: { url: data:...;base64,... } }."""
    from PIL import Image

    path = path.resolve()
    with Image.open(path) as img:
        pil = img.convert("RGB")
    b64 = _openai_prepare_image(pil)
    return {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}}


def classify_openai(api_key: str, paths: list[Path], args) -> list[dict]:
    """
    Call OpenAI omni-moderation-latest. API allows max 1 image per request, so we send
    one request per file (one image for images, one frame for videos). Return list of
    { filename, nsfw, safe, unsafe, top_class } in same order as paths.
    """
    from PIL import Image

    def _get(r, key, default=None):
        if hasattr(r, "model_dump"):
            d = r.model_dump()
            return d.get(key, default)
        return getattr(r, key, default)

    def _score(scores, key):
        if scores is None:
            return 0.0
        if isinstance(scores, dict):
            return float(scores.get(key) or 0)
        return float(getattr(scores, key, 0) or 0)

    def _one_image_input(path: Path, file_type: str):
        """One image: either from file or one frame from video. Returns single-element list for API."""
        if file_type == "image":
            inp = _openai_image_input(path)
            return [inp]
        import cv2
        cap = cv2.VideoCapture(str(path))
        if not cap.isOpened():
            raise RuntimeError(f"could not open video: {path}")
        try:
            total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) or 1
            idx = total_frames // 2 if total_frames else 0  # middle frame
            cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
            ret, frame = cap.read()
            if not ret:
                raise RuntimeError(f"could not read frame from {path}")
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            pil = Image.fromarray(frame_rgb)
            b64 = _openai_prepare_image(pil)
            return [{"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}}]
        finally:
            cap.release()

    from openai import OpenAI

    client = OpenAI(api_key=api_key.strip())
    debug = getattr(args, "debug", False)
    max_retries = 4
    backoff_base = 5.0
    out = []

    for path_idx, path in enumerate(paths):
        path = path.resolve()
        filename = path.name
        if not path.is_file():
            out.append({"filename": filename, "error": f"not a file: {path}"})
            continue
        try:
            file_type = get_file_type(path)
        except ValueError as e:
            out.append({"filename": filename, "error": str(e)})
            continue

        try:
            input_list = _one_image_input(path, file_type)
        except Exception as e:
            out.append({"filename": filename, "error": str(e)})
            continue

        if debug:
            payload_approx = len(input_list[0].get("image_url", {}).get("url", ""))
            print(f"[openai] File {path_idx + 1}/{len(paths)}: 1 request, ~{payload_approx // 1024} KiB", file=sys.stderr)

        last_error = None
        for attempt in range(max_retries):
            try:
                if debug and attempt > 0:
                    print(f"[openai] Retry attempt {attempt + 1}/{max_retries} for {filename}", file=sys.stderr)
                response = client.moderations.create(
                    model="omni-moderation-latest",
                    input=input_list,
                    timeout=120.0,
                )
                if debug:
                    print(f"[openai] Request succeeded for {filename}", file=sys.stderr)
                break
            except Exception as e:
                last_error = e
                status = getattr(e, "status_code", None)
                if status is None and hasattr(e, "response") and e.response is not None:
                    status = getattr(e.response, "status_code", None)
                err_str = str(e).lower()
                is_429_invalid = (
                    status == 429
                    and ("invalid_request_error" in err_str or "too many requests" in err_str)
                )
                is_retryable = (
                    (status in (500, 502, 503))
                    or (status == 429 and not is_429_invalid)
                    or ("rate_limit" in err_str and "too many requests" not in err_str)
                )
                if debug:
                    print(f"[openai] Request failed: {e} (status={status}, retryable={is_retryable})", file=sys.stderr)
                if is_retryable and attempt < max_retries - 1:
                    wait = backoff_base * (2**attempt)
                    if debug:
                        print(f"[openai] Waiting {wait:.0f}s before retry...", file=sys.stderr)
                    time.sleep(wait)
                else:
                    raise
        else:
            if last_error is not None:
                raise last_error

        r = response.results[0]
        if debug:
            raw = r.model_dump() if hasattr(r, "model_dump") else (vars(r) if hasattr(r, "__dict__") else str(r))
            if isinstance(raw, dict):
                print(f"[openai] Full result for {filename}:\n{json.dumps(raw, indent=2)}", file=sys.stderr)
            else:
                print(f"[openai] Full result for {filename}: {raw}", file=sys.stderr)
        flagged = _get(r, "flagged", False)
        scores = _get(r, "category_scores")
        sexual = _score(scores, "sexual")
        violence = _score(scores, "violence")
        unsafe = round(max(sexual, violence), 3)
        safe = round(1.0 - unsafe, 3)
        is_nsfw = unsafe > args.threshold or flagged
        out.append({
            "filename": filename,
            "nsfw": is_nsfw,
            "safe": safe,
            "unsafe": unsafe,
            "top_class": "OPENAI",
        })

    return out


def _sightengine_multipart(api_user: str, api_secret: str, file_path: Path, is_video: bool) -> tuple[bytes, str]:
    """Build multipart/form-data body for Sightengine. Returns (body, boundary)."""
    boundary = "----nude_detector_sightengine_" + base64.b64encode(os.urandom(12)).decode("ascii").rstrip("=")
    crlf = b"\r\n"
    parts = []
    for name, value in [
        ("models", "nudity-2.1"),
        ("api_user", api_user),
        ("api_secret", api_secret),
    ]:
        parts.append(f"--{boundary}".encode())
        parts.append(f'Content-Disposition: form-data; name="{name}"'.encode())
        parts.append(b"")
        parts.append(value.encode() if isinstance(value, str) else str(value).encode())
    parts.append(f"--{boundary}".encode())
    filename = file_path.name
    mime = "video/mp4" if is_video else "image/jpeg"
    parts.append(f'Content-Disposition: form-data; name="media"; filename="{filename}"'.encode())
    parts.append(f"Content-Type: {mime}".encode())
    parts.append(b"")
    parts.append(file_path.read_bytes())
    parts.append(f"--{boundary}--".encode())
    parts.append(b"")
    body = crlf.join(parts)
    return body, boundary


def _flatten_nudity(nudity: dict, prefix: str = "") -> dict[str, float]:
    """Flatten nested nudity dict to dot-key -> score. Only float values (scores) are kept."""
    out = {}
    for k, v in nudity.items():
        key = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict):
            out.update(_flatten_nudity(v, key))
        elif isinstance(v, (int, float)) and not isinstance(v, bool):
            out[key] = float(v)
    return out


def _nudity_to_unsafe_and_class(flat_scores: dict[str, float]) -> tuple[float, str]:
    """From flattened Sightengine scores (dot-key -> score) return (unsafe_score, top_class).
    Only classes in SIGHTENGINE_NSFW_CLASSES_ENABLED count. Unsafe = max of their scores.
    top_class = enabled class with highest score (prefer earlier in SIGHTENGINE_INTENSITY_ORDER on tie).
    """
    enabled = SIGHTENGINE_NSFW_CLASSES_ENABLED
    scores = {k: v for k, v in flat_scores.items() if k in enabled}
    unsafe = max(scores.values(), default=0.0)
    if not scores:
        return round(unsafe, 3), "none"
    best_score = max(scores.values())
    candidates = [k for k, v in scores.items() if v == best_score]
    # Prefer order: intensity first (by SIGHTENGINE_INTENSITY_ORDER), then suggestive, then context
    for c in SIGHTENGINE_INTENSITY_ORDER:
        if c in candidates:
            return round(unsafe, 3), c
    for c in sorted(candidates):
        if c.startswith("suggestive_classes."):
            return round(unsafe, 3), c
    for c in sorted(candidates):
        if c.startswith("context."):
            return round(unsafe, 3), c
    return round(unsafe, 3), candidates[0]


def classify_sightengine(api_user: str, api_secret: str, paths: list[Path], args) -> list[dict]:
    """
    Call Sightengine nudity-2.1 (images: check.json; videos: video/check-sync.json).
    Return list of { filename, nsfw, safe, unsafe, top_class } in same order as paths.
    """
    debug = getattr(args, "debug", False)
    out = []

    for path in paths:
        path = path.resolve()
        filename = path.name
        if not path.is_file():
            out.append({"filename": filename, "error": f"not a file: {path}"})
            continue
        try:
            file_type = get_file_type(path)
        except ValueError as e:
            out.append({"filename": filename, "error": str(e)})
            continue

        is_video = file_type == "video"
        url = SIGHTENGINE_VIDEO_SYNC_URL if is_video else SIGHTENGINE_IMAGE_URL
        try:
            body, boundary = _sightengine_multipart(api_user, api_secret, path, is_video)
        except Exception as e:
            out.append({"filename": filename, "error": str(e)})
            continue

        req = urllib.request.Request(
            url,
            data=body,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            try:
                err_body = e.read().decode("utf-8")
                err_json = json.loads(err_body)
                msg = err_json.get("message", err_json.get("error", err_body))
            except Exception:
                msg = str(e)
            out.append({"filename": filename, "error": f"Sightengine API: {msg}"})
            continue
        except Exception as e:
            out.append({"filename": filename, "error": str(e)})
            continue

        if data.get("status") != "success":
            out.append({"filename": filename, "error": data.get("message", "Sightengine returned non-success")})
            continue

        if is_video:
            frames = (data.get("data") or {}).get("frames") or []
            if not frames:
                out.append({"filename": filename, "error": "No frames in video response"})
                continue
            # Flatten each frame's nudity and take max per key across frames
            flat_scores = {}
            for frame in frames:
                nud = frame.get("nudity") or {}
                for k, v in _flatten_nudity(nud).items():
                    flat_scores[k] = max(flat_scores.get(k, 0.0), v)
        else:
            nudity = data.get("nudity") or {}
            if debug:
                print(f"[sightengine] Full result for {filename}:\n{json.dumps(nudity, indent=2)}", file=sys.stderr)
            flat_scores = _flatten_nudity(nudity)

        if is_video and debug:
            print(f"[sightengine] Full result (flat) for {filename}:\n{json.dumps(flat_scores, indent=2)}", file=sys.stderr)

        unsafe, top_class = _nudity_to_unsafe_and_class(flat_scores)
        safe = round(1.0 - unsafe, 3)
        is_nsfw = unsafe > args.threshold
        out.append({
            "filename": filename,
            "nsfw": is_nsfw,
            "safe": safe,
            "unsafe": unsafe,
            "top_class": top_class,
        })

    return out


def _run_backend(backend: str, paths: list[Path], args: argparse.Namespace) -> tuple[list, list, bool]:
    """Run a single backend. Returns (results, errors, any_nsfw). Raises on fatal errors (import, missing creds)."""
    results: list = []
    errors: list = []
    any_nsfw = False

    if backend == "nudenet":
        try:
            from nudenet import NudeDetector
        except ImportError as e:
            raise RuntimeError(f"failed to import nudenet: {e}") from e
        nsfw_classes = SENSITIVITY_CLASSES[args.sensitivity]
        detector = NudeDetector()
        for p in paths:
            r = classify_one_nudenet(detector, p, args, nsfw_classes)
            results.append(r)
            if "error" in r:
                errors.append(f"{r['filename']}: {r['error']}")
            elif r.get("nsfw"):
                any_nsfw = True
    elif backend == "falconsai":
        try:
            from transformers import pipeline
        except ImportError as e:
            raise RuntimeError(f"failed to import transformers (required for falconsai): {e}") from e
        hf_cache = (
            os.environ.get("HF_HUB_CACHE")
            or os.environ.get("HUGGINGFACE_HUB_CACHE")
            or str(Path(__file__).resolve().parent / ".cache" / "huggingface")
        )
        Path(hf_cache).mkdir(parents=True, exist_ok=True)
        classifier = pipeline(
            "image-classification",
            model="Falconsai/nsfw_image_detection",
            model_kwargs={"cache_dir": hf_cache},
        )
        for p in paths:
            r = classify_one_falconsai(classifier, p, args)
            results.append(r)
            if "error" in r:
                errors.append(f"{r['filename']}: {r['error']}")
            elif r.get("nsfw"):
                any_nsfw = True
    elif backend == "openai":
        api_key = getattr(args, "api_key", None) or os.environ.get("OPENAI_API_KEY")
        if not api_key or not (api_key if isinstance(api_key, str) else "").strip():
            raise RuntimeError("--api-key or OPENAI_API_KEY required for backend openai")
        openai_results = classify_openai(api_key, paths, args)
        for r in openai_results:
            results.append(r)
            if "error" in r:
                errors.append(f"{r['filename']}: {r['error']}")
            elif r.get("nsfw"):
                any_nsfw = True
    elif backend == "sightengine":
        api_user = getattr(args, "sightengine_api_user", None) or os.environ.get("SIGHTENGINE_API_USER")
        api_secret = getattr(args, "sightengine_api_secret", None) or os.environ.get("SIGHTENGINE_API_SECRET")
        if not api_user or not api_secret:
            raise RuntimeError("--sightengine-api-user and --sightengine-api-secret (or env) required for backend sightengine")
        se_results = classify_sightengine((api_user or "").strip(), (api_secret or "").strip(), paths, args)
        for r in se_results:
            results.append(r)
            if "error" in r:
                errors.append(f"{r['filename']}: {r['error']}")
            elif r.get("nsfw"):
                any_nsfw = True
    else:
        raise ValueError(f"Unknown backend: {backend!r}")
    return results, errors, any_nsfw


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
        choices=["nudenet", "falconsai", "openai", "sightengine"],
        default="sightengine",
        help="Backend: nudenet, falconsai, openai (omni-moderation-latest), or sightengine (nudity-2.1); falls back to nudenet on failure",
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("OPENAI_API_KEY"),
        help="OpenAI API key (required when --backend openai; else OPENAI_API_KEY env)",
    )
    parser.add_argument(
        "--sightengine-api-user",
        default=os.environ.get("SIGHTENGINE_API_USER"),
        help="Sightengine API user (required when --backend sightengine)",
    )
    parser.add_argument(
        "--sightengine-api-secret",
        default=os.environ.get("SIGHTENGINE_API_SECRET"),
        help="Sightengine API secret (required when --backend sightengine)",
    )
    parser.add_argument("--debug", action="store_true", help="Print debug messages to stderr")
    args = parser.parse_args()

    primary = args.backend
    fallback_reason: str | None = None
    backend_used = primary
    try:
        results, errors, any_nsfw = _run_backend(primary, args.path, args)
    except Exception as e:
        if primary == "nudenet":
            print(f"Error: {e}", file=sys.stderr)
            print(f"Python used: {sys.executable!s}", file=sys.stderr)
            return 2
        fallback_reason = f"Primary backend {primary!r} failed: {e}"
        print(f"{fallback_reason}. Falling back to nudenet.", file=sys.stderr)
        try:
            results, errors, any_nsfw = _run_backend("nudenet", args.path, args)
            backend_used = "nudenet"
        except Exception as e2:
            print(f"Error: nudenet fallback also failed: {e2}", file=sys.stderr)
            return 2
    else:
        if errors and primary != "nudenet":
            fallback_reason = f"Primary backend {primary!r} had errors"
            print(f"{fallback_reason}. Falling back to nudenet.", file=sys.stderr)
            try:
                results, errors, any_nsfw = _run_backend("nudenet", args.path, args)
                backend_used = "nudenet"
            except Exception as e2:
                print(f"Error: nudenet fallback also failed: {e2}", file=sys.stderr)
                return 2

    success = len(errors) == 0
    out = {"success": success, "nsfw": any_nsfw, "backend_used": backend_used}
    if fallback_reason is not None:
        out["fallback_reason"] = fallback_reason
    if not success:
        out["msg"] = "; ".join(errors)
    if args.full_results:
        out["results"] = results
    print(json.dumps(out, indent=2))
    return 0 if success else 2


if __name__ == "__main__":
    sys.exit(main())
