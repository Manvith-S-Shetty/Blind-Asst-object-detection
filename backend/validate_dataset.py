#!/usr/bin/env python3
"""
Dataset Validation Tool for Blind Assistant
Validates YOLO format dataset annotations, bounding boxes, class IDs, and split integrity.

Usage:
    python backend/validate_dataset.py --dataset backend/evaluation_dataset
    python backend/validate_dataset.py --dataset data/indoor_obstacles --data-yaml backend/indoor_obstacles.yaml
"""

import argparse
import os
import sys
from collections import Counter, defaultdict
from typing import Dict, List, Optional, Set, Tuple

import cv2

HIGH_PRIORITY_CLASSES = {
    'person', 'chair', 'couch', 'bed', 'dining table',
    'backpack', 'suitcase', 'handbag', 'toilet', 'potted plant',
}


def parse_simple_yaml(file_path: str) -> dict:
    """Zero-dependency parser for dataset YAML files."""
    try:
        import yaml
        with open(file_path, 'r', encoding='utf-8') as f:
            return yaml.safe_load(f) or {}
    except ImportError:
        pass

    result = {}
    current_key = None
    with open(file_path, 'r', encoding='utf-8') as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            if line.startswith((' ', '\t')) and current_key:
                if ':' in stripped:
                    k, v = stripped.split(':', 1)
                    k = k.strip()
                    v = v.strip().strip("'\"")
                    try:
                        k_parsed = int(k)
                    except ValueError:
                        k_parsed = k
                    if not isinstance(result[current_key], dict):
                        result[current_key] = {}
                    result[current_key][k_parsed] = v
                elif stripped.startswith('- '):
                    val = stripped[2:].strip().strip("'\"")
                    if not isinstance(result[current_key], list):
                        result[current_key] = []
                    result[current_key].append(val)
            elif ':' in stripped:
                k, v = stripped.split(':', 1)
                k = k.strip()
                v = v.strip().strip("'\"")
                if not v:
                    current_key = k
                    result[current_key] = {}
                else:
                    current_key = None
                    result[k] = v
    return result


def load_class_names(
    data_yaml_path: Optional[str] = None, labels_txt_path: Optional[str] = None
) -> Tuple[Dict[int, str], Optional[Set[str]]]:
    """Loads class names from either data.yaml or labels.txt."""
    names_dict: Dict[int, str] = {}
    relevant_set: Optional[Set[str]] = None

    if data_yaml_path and os.path.exists(data_yaml_path):
        cfg = parse_simple_yaml(data_yaml_path)
        names = cfg.get('names', {})
        if isinstance(names, dict):
            names_dict = {int(k): str(v) for k, v in names.items()}
        elif isinstance(names, list):
            names_dict = {i: str(v) for i, v in enumerate(names)}
        if 'relevant_classes' in cfg:
            relevant_set = set(cfg['relevant_classes'])
        return names_dict, relevant_set

    if labels_txt_path and os.path.exists(labels_txt_path):
        with open(labels_txt_path, 'r', encoding='utf-8') as f:
            lines = [line.strip() for line in f if line.strip()]
        names_dict = {i: name for i, name in enumerate(lines)}
        return names_dict, relevant_set

    # Fallback to standard COCO 80 names
    return {}, None


def find_dataset_splits(base_dir: str) -> List[Tuple[str, str, str]]:
    """Identifies dataset layout: either splits (train/val/test) or a single directory."""
    splits = []
    # Check split layout: images/train, labels/train, etc.
    for split_name in ['train', 'val', 'test']:
        img_split = os.path.join(base_dir, 'images', split_name)
        lbl_split = os.path.join(base_dir, 'labels', split_name)
        if os.path.isdir(img_split):
            splits.append((split_name, img_split, lbl_split))

    if splits:
        return splits

    # Check flat layout: images/, labels/
    img_flat = os.path.join(base_dir, 'images')
    lbl_flat = os.path.join(base_dir, 'labels')
    if os.path.isdir(img_flat):
        splits.append(('all', img_flat, lbl_flat))
        return splits

    # Direct directory check
    splits.append(('root', base_dir, base_dir))
    return splits


def get_video_prefix(filename: str) -> str:
    """Extracts clip/video prefix from filename (e.g. 'livingroom1_f001.jpg' -> 'livingroom1')."""
    base = os.path.splitext(filename)[0]
    for separator in ['_f', '_frame', '_', '-']:
        if separator in base:
            return base.split(separator)[0]
    return base


def validate_dataset(
    dataset_dir: str,
    data_yaml_path: Optional[str] = None,
    labels_txt_path: Optional[str] = None,
) -> bool:
    """Runs comprehensive validation across dataset splits and annotations."""
    print("=" * 72)
    print("  BLIND ASSISTANT: DATASET VALIDATION TOOL")
    print(f"  Target Directory: {os.path.abspath(dataset_dir)}")
    print("=" * 72)

    if not os.path.isdir(dataset_dir):
        print(f"  [ERROR] Dataset directory not found: {dataset_dir}")
        return False

    class_names, relevant_classes = load_class_names(data_yaml_path, labels_txt_path)
    if class_names:
        print(f"  Loaded {len(class_names)} configured classes.")
    else:
        print("  [INFO] No class definition file loaded. Class bounds check will be advisory.")

    splits = find_dataset_splits(dataset_dir)
    if not splits:
        print(f"  [ERROR] No image directories found in: {dataset_dir}")
        return False

    errors: List[str] = []
    warnings: List[str] = []

    total_images = 0
    total_labels = 0
    total_boxes = 0

    split_prefixes: Dict[str, Set[str]] = defaultdict(set)
    class_counts_by_split: Dict[str, Counter] = defaultdict(Counter)

    for split_name, img_dir, lbl_dir in splits:
        print(f"\n  Checking split: [{split_name}]")
        print(f"    Images: {img_dir}")
        print(f"    Labels: {lbl_dir}")

        if not os.path.exists(lbl_dir):
            warnings.append(f"Split [{split_name}]: Labels directory does not exist: {lbl_dir}")
            os.makedirs(lbl_dir, exist_ok=True)

        image_files = [
            f for f in sorted(os.listdir(img_dir))
            if f.lower().endswith(('.jpg', '.jpeg', '.png', '.bmp', '.webp'))
        ]
        label_files = [
            f for f in sorted(os.listdir(lbl_dir))
            if f.lower().endswith('.txt')
        ] if os.path.exists(lbl_dir) else []

        total_images += len(image_files)
        total_labels += len(label_files)

        img_basenames = {os.path.splitext(f)[0]: f for f in image_files}
        lbl_basenames = {os.path.splitext(f)[0]: f for f in label_files}

        # Check for unreadable or missing files
        for base, img_file in img_basenames.items():
            img_path = os.path.join(img_dir, img_file)
            prefix = get_video_prefix(img_file)
            split_prefixes[split_name].add(prefix)

            # Test reading image
            try:
                img = cv2.imread(img_path)
                if img is None:
                    errors.append(f"Split [{split_name}]: Corrupt image file: {img_file}")
                    continue
                h, w = img.shape[:2]
                if h <= 0 or w <= 0:
                    errors.append(f"Split [{split_name}]: Invalid image dimensions for {img_file}: {w}x{h}")
            except Exception as e:
                errors.append(f"Split [{split_name}]: Error reading image {img_file}: {e}")
                continue

            # Check if corresponding label exists
            if base not in lbl_basenames:
                warnings.append(
                    f"Split [{split_name}]: Image without label file: {img_file} "
                    f"(If background image with no obstacles, create an empty .txt file)"
                )
            else:
                lbl_file = lbl_basenames[base]
                lbl_path = os.path.join(lbl_dir, lbl_file)
                # Parse label file
                with open(lbl_path, 'r', encoding='utf-8') as f:
                    for line_idx, line in enumerate(f, start=1):
                        raw_line = line.strip()
                        if not raw_line:
                            continue  # blank line allowed
                        parts = raw_line.split()
                        if len(parts) != 5:
                            errors.append(
                                f"Split [{split_name}] {lbl_file}:{line_idx} - Invalid format. "
                                f"Expected 5 values (class cx cy w h), found {len(parts)}: '{raw_line}'"
                            )
                            continue

                        # Check class ID
                        try:
                            cls_id = int(parts[0])
                        except ValueError:
                            errors.append(f"Split [{split_name}] {lbl_file}:{line_idx} - Non-integer class ID: '{parts[0]}'")
                            continue

                        if class_names and (cls_id < 0 or cls_id >= len(class_names)):
                            errors.append(
                                f"Split [{split_name}] {lbl_file}:{line_idx} - Class ID {cls_id} out of range [0..{len(class_names)-1}]"
                            )

                        # Check coordinates
                        try:
                            cx = float(parts[1])
                            cy = float(parts[2])
                            bw = float(parts[3])
                            bh = float(parts[4])
                        except ValueError:
                            errors.append(f"Split [{split_name}] {lbl_file}:{line_idx} - Non-numeric coordinates: '{raw_line}'")
                            continue

                        # Box range check
                        if not (0.0 <= cx <= 1.0 and 0.0 <= cy <= 1.0):
                            errors.append(
                                f"Split [{split_name}] {lbl_file}:{line_idx} - Center coordinates out of [0, 1] range: cx={cx}, cy={cy}"
                            )
                        if bw <= 0.0 or bh <= 0.0:
                            errors.append(
                                f"Split [{split_name}] {lbl_file}:{line_idx} - Non-positive box dimension: w={bw}, h={bh}"
                            )
                        if bw > 1.05 or bh > 1.05:
                            warnings.append(
                                f"Split [{split_name}] {lbl_file}:{line_idx} - Box dimensions exceed image bounds: w={bw}, h={bh}"
                            )

                        # Tiny box warning (< 5 pixels on 640 scale)
                        if bw < 0.008 or bh < 0.008:
                            warnings.append(
                                f"Split [{split_name}] {lbl_file}:{line_idx} - Extremely small box (likely noise): w={bw:.4f}, h={bh:.4f}"
                            )

                        total_boxes += 1
                        class_counts_by_split[split_name][cls_id] += 1

        # Check for orphaned label files
        for base, lbl_file in lbl_basenames.items():
            if base not in img_basenames:
                warnings.append(f"Split [{split_name}]: Orphaned label file with no image: {lbl_file}")

    # Check for Split Contamination (Data Leakage)
    split_names = list(split_prefixes.keys())
    for i in range(len(split_names)):
        for j in range(i + 1, len(split_names)):
            s1, s2 = split_names[i], split_names[j]
            overlap = split_prefixes[s1].intersection(split_prefixes[s2])
            # Only check if meaningful prefix found
            overlap = {p for p in overlap if p and not p.isdigit()}
            if overlap:
                errors.append(
                    f"DATA LEAKAGE DETECTED! Frames from the same video clip(s) {sorted(overlap)} "
                    f"exist in BOTH '{s1}' and '{s2}' splits! "
                    f"Always put all frames from a single video into ONE split."
                )

    # Print Summary & Class Distribution
    print("\n" + "=" * 72)
    print("  DATASET VALIDATION SUMMARY")
    print("=" * 72)
    print(f"  Total Images Found:      {total_images}")
    print(f"  Total Label Files Found: {total_labels}")
    print(f"  Total Bounding Boxes:    {total_boxes}")
    print(f"  Errors Detected:         {len(errors)}")
    print(f"  Warnings Detected:       {len(warnings)}")
    print("-" * 72)

    # Class Histogram Table
    combined_counts: Counter = Counter()
    for s_counts in class_counts_by_split.values():
        combined_counts.update(s_counts)

    if combined_counts:
        print(f"\n  {'ID':<5} {'Class Label':<18} {'Total':<8} " + " ".join([f"{s[0][:5]:<8}" for s in splits]))
        print("  " + "-" * 68)
        for cls_id in sorted(combined_counts.keys()):
            name = class_names.get(cls_id, f"class_{cls_id}")
            total_c = combined_counts[cls_id]
            split_cols = " ".join([f"{class_counts_by_split[s[0]][cls_id]:<8}" for s in splits])
            is_priority = "(*)" if name in HIGH_PRIORITY_CLASSES else "   "
            print(f"  {cls_id:<5} {name:<18} {total_c:<8} {split_cols} {is_priority}")
        print("  (*) = High-priority assistive navigation obstacle class.")
    else:
        print("  [!] No annotated bounding boxes found in dataset.")

    # Print Warnings
    if warnings:
        print(f"\n  WARNINGS ({len(warnings)}):")
        for w in warnings[:15]:
            print(f"    [WARN] {w}")
        if len(warnings) > 15:
            print(f"    ... and {len(warnings) - 15} more warnings.")

    # Print Errors
    if errors:
        print(f"\n  ERRORS ({len(errors)}):")
        for e in errors[:20]:
            print(f"    [ERROR] {e}")
        if len(errors) > 20:
            print(f"    ... and {len(errors) - 20} more errors.")
        print("\n" + "=" * 72)
        print("  VERDICT: FAILED (Resolve errors before proceeding to training)")
        print("=" * 72 + "\n")
        return False

    print("\n" + "=" * 72)
    print("  VERDICT: PASSED (Dataset annotations are structurally valid!)")
    print("=" * 72 + "\n")
    return True


def main():
    parser = argparse.ArgumentParser(description="Validate YOLO dataset annotations and split integrity.")
    parser.add_argument(
        '--dataset',
        '--dataset-dir',
        dest='dataset',
        default=None,
        help='Path to dataset directory (e.g. backend/evaluation_dataset or data/indoor_obstacles)',
    )
    parser.add_argument(
        '--data',
        '--data-yaml',
        dest='data_yaml',
        default='backend/evaluation_dataset/dataset.yaml',
        help='Path to dataset YAML file (e.g. dataset.yaml or backend/indoor_obstacles.yaml)',
    )
    parser.add_argument(
        '--labels-txt',
        default='frontend/assets/models/labels.txt',
        help='Path to labels.txt fallback',
    )

    args = parser.parse_args()

    yaml_path = args.data_yaml if (args.data_yaml and os.path.exists(args.data_yaml)) else None
    dataset_dir = args.dataset

    # If dataset_dir is not provided, try to infer it from yaml or default to yaml directory
    if not dataset_dir:
        if yaml_path:
            cfg = parse_simple_yaml(yaml_path)
            if 'path' in cfg:
                raw_path = cfg['path']
                if os.path.isabs(raw_path) and os.path.exists(raw_path):
                    dataset_dir = raw_path
                elif os.path.exists(raw_path):
                    dataset_dir = raw_path
                else:
                    yaml_dir = os.path.dirname(os.path.abspath(yaml_path))
                    candidate = os.path.normpath(os.path.join(yaml_dir, raw_path))
                    if os.path.exists(candidate):
                        dataset_dir = candidate
                    else:
                        dataset_dir = yaml_dir
            else:
                dataset_dir = os.path.dirname(os.path.abspath(yaml_path))
        else:
            dataset_dir = 'backend/evaluation_dataset'

    txt_path = args.labels_txt if os.path.exists(args.labels_txt) else None

    success = validate_dataset(dataset_dir, yaml_path, txt_path)
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
