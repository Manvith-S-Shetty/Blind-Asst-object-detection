#!/usr/bin/env python3
"""
Automated Video Frame Extraction Tool for Blind Assistant
Extracts non-redundant, sharp frames from mobile phone navigation videos for labeling.

Features:
- Sample rate control (e.g. 1 frame per second instead of 30fps duplicates)
- Blur rejection (detects motion-blurred frames using Laplacian variance)
- Stagnation filtering (skips nearly identical frames when stationary)
- Consistent video prefixing (enables non-leaking train/val/test splits)

Usage:
    python backend/extract_frames.py --video my_video.mp4 --output-dir data/extracted_frames --fps 1.0
    python backend/extract_frames.py --input-dir data/raw_videos --output-dir data/extracted_frames --fps 1.0
"""

import argparse
import os
import sys
from typing import List

import cv2
import numpy as np


def compute_blur_score(gray_frame: np.ndarray) -> float:
    """Computes Laplacian variance. Lower values indicate blurriness."""
    return float(cv2.Laplacian(gray_frame, cv2.CV_64F).var())


def compute_frame_difference(gray1: np.ndarray, gray2: np.ndarray) -> float:
    """Computes normalized absolute pixel difference between consecutive frames."""
    diff = cv2.absdiff(gray1, gray2)
    return float(np.mean(diff) / 255.0)


def extract_frames_from_video(
    video_path: str,
    output_dir: str,
    target_fps: float = 1.0,
    blur_threshold: float = 35.0,
    min_diff_threshold: float = 0.04,
    prefix_override: str = "",
) -> int:
    """Extracts representative frames from a video file."""
    if not os.path.exists(video_path):
        print(f"  [ERROR] Video file not found: {video_path}")
        return 0

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        print(f"  [ERROR] Could not open video file: {video_path}")
        return 0

    source_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total_source_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)

    # Calculate frame step interval
    step = max(1, int(round(source_fps / target_fps)))

    base_name = prefix_override if prefix_override else os.path.splitext(os.path.basename(video_path))[0]
    # Clean prefix of spaces or special characters
    base_name = "".join([c if c.isalnum() or c == '_' else '_' for c in base_name])

    os.makedirs(output_dir, exist_ok=True)

    print(f"\n  Processing video: {os.path.basename(video_path)}")
    print(f"    Source resolution: {width}x{height} @ {source_fps:.1f} FPS (Total frames: {total_source_frames})")
    print(f"    Extraction rate:   {target_fps:.1f} FPS (sampling every {step} frames)")

    saved_count = 0
    skipped_blur = 0
    skipped_similar = 0
    frame_idx = 0

    prev_saved_gray: np.ndarray = None

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        if frame_idx % step == 0:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

            # 1. Blur Check
            blur_score = compute_blur_score(gray)
            if blur_score < blur_threshold:
                skipped_blur += 1
                frame_idx += 1
                continue

            # 2. Stagnation / Similarity Check
            if prev_saved_gray is not None:
                # Downsample for quick similarity comparison
                small_curr = cv2.resize(gray, (160, 120))
                small_prev = cv2.resize(prev_saved_gray, (160, 120))
                diff = compute_frame_difference(small_curr, small_prev)
                if diff < min_diff_threshold:
                    skipped_similar += 1
                    frame_idx += 1
                    continue

            # Save frame
            saved_count += 1
            filename = f"{base_name}_f{saved_count:04d}.jpg"
            out_path = os.path.join(output_dir, filename)
            cv2.imwrite(out_path, frame, [int(cv2.IMWRITE_JPEG_QUALITY), 95])
            prev_saved_gray = gray

        frame_idx += 1

    cap.release()

    print(f"    Extracted & saved: {saved_count} sharp frames")
    print(f"    Filtered out:      {skipped_blur} blurry frames, {skipped_similar} near-identical stationary frames")
    return saved_count


def process_inputs(args):
    video_files: List[str] = []

    if args.video:
        video_files.append(args.video)
    elif args.input_dir:
        if not os.path.isdir(args.input_dir):
            print(f"Error: input directory does not exist: {args.input_dir}")
            sys.exit(1)
        for root, _, files in os.walk(args.input_dir):
            for f in sorted(files):
                if f.lower().endswith(('.mp4', '.mov', '.avi', '.mkv', '.webm', '.3gp')):
                    video_files.append(os.path.join(root, f))

    if not video_files:
        print("No video files specified or found.")
        print("Provide a video via --video <file> or a directory via --input-dir <dir>.")
        sys.exit(1)

    print("=" * 72)
    print("  BLIND ASSISTANT: AUTOMATED VIDEO FRAME EXTRACTOR")
    print(f"  Target Output: {os.path.abspath(args.output_dir)}")
    print(f"  Total Videos:  {len(video_files)}")
    print("=" * 72)

    total_extracted = 0
    for v_path in video_files:
        count = extract_frames_from_video(
            video_path=v_path,
            output_dir=args.output_dir,
            target_fps=args.fps,
            blur_threshold=args.blur_threshold,
            min_diff_threshold=args.min_diff,
        )
        total_extracted += count

    print("\n" + "=" * 72)
    print(f"  EXTRACTION COMPLETE: {total_extracted} frames saved to {args.output_dir}")
    print("  Next step: Annotate bounding boxes using Label Studio or CVAT.")
    print("=" * 72 + "\n")


def main():
    parser = argparse.ArgumentParser(description="Extract clean, non-redundant frames from mobile videos.")
    parser.add_argument('--video', help='Path to a single video file (MP4/MOV)')
    parser.add_argument('--input-dir', help='Path to directory containing video files')
    parser.add_argument(
        '--output-dir',
        default='data/extracted_frames',
        help='Target directory for extracted JPG frames (default: data/extracted_frames)',
    )
    parser.add_argument(
        '--fps',
        type=float,
        default=1.0,
        help='Frames to extract per second of video (default: 1.0)',
    )
    parser.add_argument(
        '--blur-threshold',
        type=float,
        default=35.0,
        help='Laplacian variance threshold to reject motion blur (default: 35.0)',
    )
    parser.add_argument(
        '--min-diff',
        type=float,
        default=0.04,
        help='Minimum pixel difference threshold to reject stationary frames (default: 0.04)',
    )

    args = parser.parse_args()
    process_inputs(args)


if __name__ == '__main__':
    main()
