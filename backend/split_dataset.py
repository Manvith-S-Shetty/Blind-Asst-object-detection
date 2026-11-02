#!/usr/bin/env python3
"""
Clip-Level Dataset Splitter for Blind Assistant
Safely splits video-extracted frames and YOLO labels into train/val/test partitions
without data leakage (ensuring near-identical frames from the same video clip
remain in the same partition).

Usage:
    python backend/split_dataset.py --images-dir data/extracted_frames --labels-dir data/labels --output-dir data/indoor_obstacles
    python backend/split_dataset.py --help
"""

import argparse
import os
import random
import re
import shutil
import sys
from collections import defaultdict
from typing import Dict, List, Optional, Set, Tuple


IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.bmp', '.webp'}


def extract_clip_prefix(filename: str) -> str:
    """
    Extracts the video/scene clip prefix from a filename.
    
    Examples:
        'living_room_01_f0023.jpg' -> 'living_room_01'
        'kitchen_walk_f0001.png'   -> 'kitchen_walk'
        'hallway_step_12.jpg'      -> 'hallway_step'
        'frame_001.jpg'            -> 'frame'
        'single_image.jpg'         -> 'single'
    """
    stem = os.path.splitext(os.path.basename(filename))[0]
    # Check for extract_frames.py pattern: <prefix>_f\d+
    match = re.match(r'^(.*)_f\d+$', stem, re.IGNORECASE)
    if match:
        return match.group(1)
    
    # Check for trailing digits: <prefix>_\d+ or <prefix>-\d+
    match = re.match(r'^(.*?)[_-]\d+$', stem)
    if match:
        return match.group(1)

    # Fallback: everything before the last underscore
    if '_' in stem:
        return stem.rsplit('_', 1)[0]

    return stem


def find_matched_pairs(
    images_dir: str, labels_dir: str
) -> Tuple[Dict[str, List[str]], Dict[str, str], List[str]]:
    """
    Finds all images and their matching YOLO label files, grouped by clip prefix.
    
    Returns:
        (clip_to_images, image_to_label, unlabelled_images)
    """
    if not os.path.exists(images_dir):
        raise FileNotFoundError(f"Images directory not found: {images_dir}")

    clip_to_images: Dict[str, List[str]] = defaultdict(list)
    image_to_label: Dict[str, str] = {}
    unlabelled_images: List[str] = []

    image_files = [
        f for f in os.listdir(images_dir)
        if os.path.splitext(f)[1].lower() in IMAGE_EXTENSIONS
    ]
    image_files.sort()

    for img_name in image_files:
        stem = os.path.splitext(img_name)[0]
        prefix = extract_clip_prefix(img_name)
        clip_to_images[prefix].append(img_name)

        # Check for label file
        label_name = f"{stem}.txt"
        label_path = os.path.join(labels_dir, label_name) if labels_dir else None
        if label_path and os.path.exists(label_path):
            image_to_label[img_name] = label_path
        else:
            unlabelled_images.append(img_name)

    return clip_to_images, image_to_label, unlabelled_images


def partition_clips(
    clip_to_images: Dict[str, List[str]],
    train_ratio: float = 0.70,
    val_ratio: float = 0.20,
    test_ratio: float = 0.10,
    seed: int = 42,
) -> Dict[str, List[str]]:
    """
    Partitions clips across train, val, and test partitions
    targeting the desired frame counts while keeping each clip whole.
    """
    total_frames = sum(len(imgs) for imgs in clip_to_images.values())
    if total_frames == 0:
        return {'train': [], 'val': [], 'test': []}

    target_train = int(round(total_frames * train_ratio))
    target_val = int(round(total_frames * val_ratio))
    # Remaining go to test
    target_test = max(0, total_frames - target_train - target_val)

    # Sort clips by frame count descending for greedy bin packing, with deterministic tie breaking
    rng = random.Random(seed)
    clips = list(clip_to_images.keys())
    rng.shuffle(clips)

    # Sort descending by length so larger clips are allocated first
    clips.sort(key=lambda c: len(clip_to_images[c]), reverse=True)

    partitions: Dict[str, List[str]] = {'train': [], 'val': [], 'test': []}
    partition_counts: Dict[str, int] = {'train': 0, 'val': 0, 'test': 0}
    targets = {'train': target_train, 'val': target_val, 'test': target_test}

    # If only 1 clip exists, put in train
    if len(clips) == 1:
        partitions['train'].append(clips[0])
        return partitions

    # If 2 clips exist and val requested, put 1 in train, 1 in val
    if len(clips) == 2:
        partitions['train'].append(clips[0])
        partitions['val'].append(clips[1])
        return partitions

    # Greedy bin assignment: place in whichever partition is furthest below target
    for clip in clips:
        clip_len = len(clip_to_images[clip])
        # Calculate deficits
        deficits = {
            p: (targets[p] - partition_counts[p])
            for p in ['train', 'val', 'test']
            if targets[p] > 0
        }
        if not deficits:
            best_split = 'train'
        else:
            best_split = max(deficits, key=deficits.get)

        partitions[best_split].append(clip)
        partition_counts[best_split] += clip_len

    return partitions


def create_dataset_yaml(
    output_dir: str,
    class_names: Optional[List[str]] = None,
) -> str:
    """Generates a dataset.yaml file in the output directory."""
    yaml_path = os.path.join(output_dir, "dataset.yaml")
    
    if not class_names:
        # Default to 30 high-priority indoor obstacle classes
        class_names = [
            'person', 'bicycle', 'car', 'motorcycle', 'bus', 'train', 'truck',
            'traffic light', 'fire hydrant', 'stop sign', 'bench', 'backpack',
            'umbrella', 'handbag', 'suitcase', 'chair', 'couch', 'potted plant',
            'bed', 'dining table', 'toilet', 'tv', 'laptop', 'microwave',
            'oven', 'sink', 'refrigerator', 'book', 'dog', 'cat',
        ]

    clean_path = os.path.abspath(output_dir).replace("\\", "/")
    lines = [
        "# YOLO Dataset Configuration",
        "# Generated by backend/split_dataset.py",
        f"path: {clean_path}",
        "train: images/train",
        "val: images/val",
        "test: images/test",
        "",
        f"nc: {len(class_names)}",
        "names:",
    ]
    for idx, name in enumerate(class_names):
        lines.append(f"  {idx}: {name}")
    lines.append("")

    with open(yaml_path, 'w', encoding='utf-8') as f:
        f.write("\n".join(lines))

    return yaml_path


def split_dataset(
    images_dir: str,
    labels_dir: str,
    output_dir: str,
    train_ratio: float = 0.70,
    val_ratio: float = 0.20,
    test_ratio: float = 0.10,
    seed: int = 42,
    move_files: bool = False,
    create_empty_labels: bool = True,
) -> bool:
    """
    Main function to split dataset safely without cross-split video frame leakage.
    """
    print("\n" + "=" * 72)
    print("  BLIND ASSISTANT: CLIP-LEVEL DATASET SPLITTER")
    print(f"  Source Images:  {os.path.abspath(images_dir)}")
    print(f"  Source Labels:  {os.path.abspath(labels_dir) if labels_dir else 'None'}")
    print(f"  Target Output:  {os.path.abspath(output_dir)}")
    print(f"  Target Ratios:  Train={train_ratio:.0%}, Val={val_ratio:.0%}, Test={test_ratio:.0%}")
    print("=" * 72)

    clip_to_images, image_to_label, unlabelled = find_matched_pairs(images_dir, labels_dir)
    total_images = sum(len(imgs) for imgs in clip_to_images.values())
    total_clips = len(clip_to_images)

    if total_images == 0:
        print("[!] Error: No valid image files found in images directory.")
        return False

    print(f"\n  Found {total_images} total frames across {total_clips} distinct video clip(s).")
    print(f"  Found {len(image_to_label)} matching label files.")
    if unlabelled:
        if create_empty_labels:
            print(f"  [i] {len(unlabelled)} image(s) have no label file. Empty .txt labels will be created (background negatives).")
        else:
            print(f"  [!] Warning: {len(unlabelled)} image(s) have no label file and will be skipped.")

    # Partition clips
    clip_partitions = partition_clips(
        clip_to_images, train_ratio, val_ratio, test_ratio, seed=seed
    )

    # Prepare destination directories
    for split in ['train', 'val', 'test']:
        os.makedirs(os.path.join(output_dir, 'images', split), exist_ok=True)
        os.makedirs(os.path.join(output_dir, 'labels', split), exist_ok=True)

    action_fn = shutil.move if move_files else shutil.copy2
    action_name = "Moved" if move_files else "Copied"

    split_stats = {'train': {'clips': 0, 'images': 0, 'labels': 0},
                   'val':   {'clips': 0, 'images': 0, 'labels': 0},
                   'test':  {'clips': 0, 'images': 0, 'labels': 0}}

    for split, clips in clip_partitions.items():
        img_dest_dir = os.path.join(output_dir, 'images', split)
        lbl_dest_dir = os.path.join(output_dir, 'labels', split)

        for clip in clips:
            split_stats[split]['clips'] += 1
            images = clip_to_images[clip]

            for img_name in images:
                src_img = os.path.join(images_dir, img_name)
                dst_img = os.path.join(img_dest_dir, img_name)
                action_fn(src_img, dst_img)
                split_stats[split]['images'] += 1

                stem = os.path.splitext(img_name)[0]
                dst_lbl = os.path.join(lbl_dest_dir, f"{stem}.txt")

                if img_name in image_to_label:
                    src_lbl = image_to_label[img_name]
                    action_fn(src_lbl, dst_lbl)
                    split_stats[split]['labels'] += 1
                elif create_empty_labels:
                    # Create empty .txt file for negative background image
                    with open(dst_lbl, 'w', encoding='utf-8') as f:
                        pass
                    split_stats[split]['labels'] += 1

    # Print summary
    print("\n" + "-" * 72)
    print("  SPLIT PARTITIONING SUMMARY (NO CROSS-SPLIT LEAKAGE)")
    print("-" * 72)
    print(f"  {'Split':<10} {'Clips':<10} {'Frames':<12} {'Percent':<10} {'Labels':<10}")
    print("  " + "-" * 56)
    for split in ['train', 'val', 'test']:
        st = split_stats[split]
        pct = (st['images'] / total_images * 100.0) if total_images > 0 else 0.0
        print(f"  {split:<10} {st['clips']:<10} {st['images']:<12} {pct:>6.1f}%    {st['labels']:<10}")
    print("-" * 72)

    # Generate dataset.yaml
    yaml_path = create_dataset_yaml(output_dir)
    print(f"\n  [OK] Successfully {action_name.lower()} files into {output_dir}")
    print(f"  [OK] Generated dataset definition: {yaml_path}")
    print("=" * 72 + "\n")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Split video frames into train/val/test partitions by clip prefix."
    )
    parser.add_argument(
        '--images-dir',
        required=True,
        help='Directory containing extracted frames (e.g. data/extracted_frames)',
    )
    parser.add_argument(
        '--labels-dir',
        default='',
        help='Directory containing YOLO format .txt annotations (e.g. data/labels)',
    )
    parser.add_argument(
        '--output-dir',
        required=True,
        help='Target output directory (e.g. data/indoor_obstacles)',
    )
    parser.add_argument(
        '--train-ratio',
        type=float,
        default=0.70,
        help='Fraction of frames for training (default: 0.70)',
    )
    parser.add_argument(
        '--val-ratio',
        type=float,
        default=0.20,
        help='Fraction of frames for validation (default: 0.20)',
    )
    parser.add_argument(
        '--test-ratio',
        type=float,
        default=0.10,
        help='Fraction of frames for held-out test (default: 0.10)',
    )
    parser.add_argument(
        '--seed',
        type=int,
        default=42,
        help='Random seed for deterministic clip allocation (default: 42)',
    )
    parser.add_argument(
        '--move',
        action='store_true',
        help='Move files instead of copying them (default: copy)',
    )
    parser.add_argument(
        '--no-empty-labels',
        action='store_true',
        help='Do not create empty .txt files for unlabelled negative frames',
    )

    args = parser.parse_args()

    # Validate ratios
    total_ratio = args.train_ratio + args.val_ratio + args.test_ratio
    if abs(total_ratio - 1.0) > 0.01:
        print(f"[!] Error: Ratios must sum to 1.0 (got {total_ratio:.2f})")
        sys.exit(1)

    success = split_dataset(
        images_dir=args.images_dir,
        labels_dir=args.labels_dir,
        output_dir=args.output_dir,
        train_ratio=args.train_ratio,
        val_ratio=args.val_ratio,
        test_ratio=args.test_ratio,
        seed=args.seed,
        move_files=args.move,
        create_empty_labels=not args.no_empty_labels,
    )

    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
