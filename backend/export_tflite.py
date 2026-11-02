#!/usr/bin/env python3
"""
Model Export and Mobile Compatibility Verification Tool
Exports fine-tuned YOLOv11 models to TensorFlow Lite format and verifies tensor compatibility
with Flutter's on-device LocalDetector service.

Usage:
    python backend/export_tflite.py --weights runs/train/yolo11n_indoor/weights/best.pt --deploy
"""

import argparse
import os
import shutil
import sys
import numpy as np


def verify_tflite_model(tflite_path: str, expected_input_shape=(1, 640, 640, 3)):
    """Verifies that the exported TFLite model is 100% compatible with Flutter LocalDetector."""
    import tensorflow as tf

    print(f"\nVerifying TFLite model: {tflite_path} ...")
    if not os.path.exists(tflite_path):
        raise FileNotFoundError(f"Exported TFLite model not found at: {tflite_path}")

    interpreter = tf.lite.Interpreter(model_path=tflite_path)
    interpreter.allocate_tensors()

    inp_details = interpreter.get_input_details()
    out_details = interpreter.get_output_details()

    if not inp_details:
        raise ValueError("Model has no input tensors!")
    if not out_details:
        raise ValueError("Model has no output tensors!")

    inp_shape = list(inp_details[0]['shape'])
    inp_dtype = inp_details[0]['dtype']

    out_shape = list(out_details[0]['shape'])
    out_dtype = out_details[0]['dtype']

    print(f"  [x] Input tensor:  shape={inp_shape}, dtype={inp_dtype.__name__}")
    print(f"  [x] Output tensor: shape={out_shape}, dtype={out_dtype.__name__}")

    # Verify input shape
    if inp_shape != list(expected_input_shape):
        raise ValueError(
            f"Input tensor shape mismatch! Expected {list(expected_input_shape)}, but got {inp_shape}. "
            f"Flutter LocalDetector requires NHWC 1x640x640x3."
        )

    # Verify output shape [1, 4 + nc, 8400]
    if len(out_shape) != 3 or out_shape[0] != 1 or out_shape[2] != 8400:
        raise ValueError(
            f"Output tensor shape mismatch! Expected [1, 4+num_classes, 8400], but got {out_shape}."
        )

    num_classes = out_shape[1] - 4
    print(f"  [x] Verified number of detected classes: {num_classes}")

    # Run dummy inference verification
    dummy_input = np.zeros(inp_shape, dtype=np.float32)
    interpreter.set_tensor(inp_details[0]['index'], dummy_input)
    interpreter.invoke()
    output_data = interpreter.get_tensor(out_details[0]['index'])

    if np.isnan(output_data).any() or np.isinf(output_data).any():
        raise ValueError("Model inference produced NaN or Inf values!")

    file_size_mb = os.path.getsize(tflite_path) / (1024 * 1024)
    print(f"  [x] Inference sanity check passed. File size: {file_size_mb:.2f} MB")
    print("  [x] Model is 100% compatible with Flutter LocalDetector!")
    return True


def export_and_verify(args):
    try:
        from ultralytics import YOLO
    except ImportError:
        print("Error: ultralytics package is not installed.")
        print("Install via: pip install ultralytics")
        sys.exit(1)

    print(f"Loading weights from: {args.weights} ...")
    model = YOLO(args.weights)

    print(f"Exporting to TFLite (half={args.half}, imgsz={args.imgsz}) ...")
    # Ultralytics export to TFLite
    exported_path = model.export(
        format="tflite",
        imgsz=args.imgsz,
        half=args.half,
    )
    print(f"Ultralytics export complete: {exported_path}")

    # Ultralytics exports to directory or .tflite file depending on version
    if os.path.isdir(exported_path):
        candidate_tflite = os.path.join(exported_path, "model.tflite")
        if not os.path.exists(candidate_tflite):
            # Find any .tflite in exported dir
            tflites = [os.path.join(exported_path, f) for f in os.listdir(exported_path) if f.endswith('.tflite')]
            if tflites:
                candidate_tflite = tflites[0]
            else:
                raise FileNotFoundError(f"No .tflite file found in {exported_path}")
    else:
        candidate_tflite = exported_path

    # Verify compatibility
    verify_tflite_model(candidate_tflite)

    if args.deploy:
        target_tflite = os.path.join(args.frontend_models_dir, "yolo11n_float16.tflite")
        backup_tflite = os.path.join(args.frontend_models_dir, "yolo11n_float16.tflite.bak")

        # Create backup of existing working model
        if os.path.exists(target_tflite):
            shutil.copyfile(target_tflite, backup_tflite)
            print(f"Created backup of previous model at: {backup_tflite}")

        shutil.copyfile(candidate_tflite, target_tflite)
        print(f"Successfully deployed replacement model to: {target_tflite}")


def main():
    parser = argparse.ArgumentParser(description="Export YOLO model to TFLite and verify compatibility.")
    parser.add_argument('--weights', default='yolo11n.pt', help='Path to PyTorch .pt weights')
    parser.add_argument('--imgsz', type=int, default=640, help='Image resolution')
    parser.add_argument('--half', action='store_true', default=True, help='Export FP16 half precision')
    parser.add_argument('--deploy', action='store_true', help='Deploy verified model to frontend/assets/models/')
    parser.add_argument(
        '--frontend-models-dir',
        default='frontend/assets/models',
        help='Target Flutter assets directory',
    )

    args = parser.parse_args()
    export_and_verify(args)


if __name__ == '__main__':
    main()
