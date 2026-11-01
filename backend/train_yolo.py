#!/usr/bin/env python3
"""
Reproducible Fine-Tuning Script for YOLOv11 Navigation Models
Part of Blind Assistant Assistive Navigation System.

Requirements:
    pip install ultralytics torch torchvision

Usage:
    python backend/train_yolo.py --data backend/indoor_obstacles.yaml --epochs 50 --imgsz 640
"""

import argparse
import os
import sys

def check_environment(data_yaml_path: str):
    """Verifies dependencies, dataset, and compute before launching fine-tuning."""
    print("=" * 70)
    print("  BLIND ASSISTANT: YOLOv11 FINE-TUNING PRE-FLIGHT CHECK")
    print("=" * 70)

    # 1. Check ultralytics and torch
    try:
        import torch
        import ultralytics
        from ultralytics import YOLO
        print(f"  [x] PyTorch version:      {torch.__version__}")
        print(f"  [x] Ultralytics version:  {ultralytics.__version__}")
        has_cuda = torch.cuda.is_available()
        device_name = torch.cuda.get_device_name(0) if has_cuda else "CPU"
        print(f"  [x] Compute device:       {device_name} (CUDA available: {has_cuda})")
        if not has_cuda:
            print("  [!] WARNING: No GPU detected. CPU training will be slow (~2-5 hrs).")
    except ImportError as e:
        print(f"  [ ] Missing dependency: {e}")
        print("      To install dependencies, run: pip install ultralytics torch torchvision")
        return False

    # 2. Check dataset configuration
    if not os.path.exists(data_yaml_path):
        print(f"  [ ] Dataset config not found: {data_yaml_path}")
        return False
    print(f"  [x] Dataset config found: {data_yaml_path}")

    # 3. Check dataset directories
    import yaml
    with open(data_yaml_path, 'r', encoding='utf-8') as f:
        data_cfg = yaml.safe_load(f)

    base_path = data_cfg.get('path', '.')
    train_rel = data_cfg.get('train', 'images/train')
    val_rel = data_cfg.get('val', 'images/val')

    train_path = os.path.join(base_path, train_rel) if not os.path.isabs(train_rel) else train_rel
    val_path = os.path.join(base_path, val_rel) if not os.path.isabs(val_rel) else val_rel

    if not os.path.exists(train_path):
        print(f"  [ ] Training images not found at: {train_path}")
        print("      Please collect and annotate indoor obstacle images before training.")
        print("      Refer to docs/indoor_dataset_collection_guide.md for collection instructions.")
        return False
    print(f"  [x] Training path found:   {train_path}")

    if not os.path.exists(val_path):
        print(f"  [ ] Validation images not found at: {val_path}")
        return False
    print(f"  [x] Validation path found: {val_path}")

    print("=" * 70)
    return True


def train(args):
    from ultralytics import YOLO

    print(f"\nInitializing YOLOv11 base model: {args.base_model} ...")
    model = YOLO(args.base_model)

    print("\nStarting fine-tuning with mobile-optimized indoor augmentations:")
    print("  - Augmentation: HSV color jitter (shadow/indoor light adaptation)")
    print("  - Augmentation: Perspective & mild rotation (phone tilt & gait sway)")
    print("  - Augmentation: Mosaic & mixup (indoor obstacle clutter)")

    # Fine-tuning parameters tuned for mobile navigation obstacles
    results = model.train(
        data=args.data,
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        patience=args.patience,
        optimizer='AdamW',
        lr0=args.lr0,
        lrf=args.lrf,
        # Indoor-specific data augmentation
        hsv_h=0.015,     # subtle hue jitter
        hsv_s=0.7,       # saturation jitter (handles varying lighting)
        hsv_v=0.4,       # brightness jitter (handles indoor hallways / dark corners)
        degrees=7.0,     # slight rotation for hand-held wobble
        translate=0.1,   # translation jitter
        scale=0.5,       # scale jitter for near vs far obstacles
        shear=2.0,       # slight shear
        mosaic=1.0,      # mosaic for multi-obstacle scenes
        mixup=0.15,      # mixup for blending
        fliplr=0.5,      # horizontal flip
        project=args.project,
        name=args.name,
        device=args.device,
        exist_ok=True,
    )

    print("\nTraining completed successfully!")
    print(f"Best model weights saved to: {os.path.join(args.project, args.name, 'weights', 'best.pt')}")
    print("\nNext step: Run backend/export_tflite.py to convert best.pt to mobile TFLite format.")


def main():
    parser = argparse.ArgumentParser(description="Fine-tune YOLOv11 on indoor obstacle dataset.")
    parser.add_argument('--data', default='backend/indoor_obstacles.yaml', help='Path to data.yaml')
    parser.add_argument('--base-model', default='yolo11n.pt', help='Base pretrained weights (yolo11n.pt)')
    parser.add_argument('--epochs', type=int, default=50, help='Number of epochs (default: 50)')
    parser.add_argument('--imgsz', type=int, default=640, help='Image resolution (default: 640)')
    parser.add_argument('--batch', type=int, default=16, help='Batch size (default: 16)')
    parser.add_argument('--patience', type=int, default=12, help='Early stopping patience (default: 12)')
    parser.add_argument('--lr0', type=float, default=0.001, help='Initial learning rate')
    parser.add_argument('--lrf', type=float, default=0.01, help='Final learning rate fraction')
    parser.add_argument('--project', default='runs/train', help='Save directory')
    parser.add_argument('--name', default='yolo11n_indoor', help='Run name')
    parser.add_argument('--device', default='', help='Device id (e.g. 0 or cpu)')

    args = parser.parse_args()

    ready = check_environment(args.data)
    if not ready:
        print("\nPre-flight check failed. Please resolve the requirements above before training.")
        sys.exit(1)

    train(args)


if __name__ == '__main__':
    main()
