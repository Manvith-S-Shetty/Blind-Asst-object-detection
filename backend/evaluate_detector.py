#!/usr/bin/env python3
"""
Repeatable Evaluation Tool for On-Device YOLO Object Detection
Used for Blind Assistant assistive navigation.

Evaluates TFLite models against labeled ground truth images:
- Computes Precision, Recall, F1 (Overall and Per-Class)
- Tracks Missed Detections (False Negatives) and Duplicate/Ghost Detections (False Positives)
- Measures Preprocessing, Inference, and NMS Latencies (ms and FPS)
- Saves full evaluation artifacts to JSON.
"""

import argparse
import json
import os
import sys
import time
from typing import Dict, List, Tuple

import cv2
import numpy as np
import tensorflow as tf

RELEVANT_CLASSES = {
    'person', 'bicycle', 'car', 'motorcycle', 'bus', 'train', 'truck',
    'traffic light', 'fire hydrant', 'stop sign', 'bench', 'backpack',
    'umbrella', 'handbag', 'suitcase', 'chair', 'couch', 'potted plant',
    'bed', 'dining table', 'toilet', 'tv', 'laptop', 'microwave',
    'oven', 'sink', 'refrigerator', 'book', 'dog', 'cat',
}


def letterbox(im: np.ndarray, new_shape=(640, 640), color=(114, 114, 114)):
    """Letterbox resize maintaining aspect ratio with neutral 114 gray padding."""
    shape = im.shape[:2]  # [h, w]
    r = min(new_shape[0] / shape[0], new_shape[1] / shape[1])
    new_unpad = (int(round(shape[1] * r)), int(round(shape[0] * r)))
    dw, dh = (new_shape[1] - new_unpad[0]) / 2, (new_shape[0] - new_unpad[1]) / 2
    if shape[::-1] != new_unpad:
        im = cv2.resize(im, new_unpad, interpolation=cv2.INTER_LINEAR)
    top, bottom = int(round(dh - 0.1)), int(round(dh + 0.1))
    left, right = int(round(dw - 0.1)), int(round(dw + 0.1))
    im = cv2.copyMakeBorder(im, top, bottom, left, right, cv2.BORDER_CONSTANT, value=color)
    return im, r, (dw, dh)


def compute_iou(box1: np.ndarray, box2: np.ndarray) -> float:
    """Computes IoU between two [x1, y1, x2, y2] boxes."""
    x1 = max(box1[0], box2[0])
    y1 = max(box1[1], box2[1])
    x2 = min(box1[2], box2[2])
    y2 = min(box1[3], box2[3])

    inter_w = max(0.0, x2 - x1)
    inter_h = max(0.0, y2 - y1)
    inter_area = inter_w * inter_h
    if inter_area <= 0:
        return 0.0

    area1 = max(0.0, box1[2] - box1[0]) * max(0.0, box1[3] - box1[1])
    area2 = max(0.0, box2[2] - box2[0]) * max(0.0, box2[3] - box2[1])
    union_area = area1 + area2 - inter_area
    return inter_area / union_area if union_area > 0 else 0.0


def nms(boxes: np.ndarray, scores: np.ndarray, iou_thresh: float) -> List[int]:
    """Standard greedy per-class Non-Maximum Suppression."""
    if len(boxes) == 0:
        return []
    x1 = boxes[:, 0]
    y1 = boxes[:, 1]
    x2 = boxes[:, 2]
    y2 = boxes[:, 3]
    areas = (x2 - x1) * (y2 - y1)
    order = scores.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        w = np.maximum(0.0, xx2 - xx1)
        h = np.maximum(0.0, yy2 - yy1)
        inter = w * h
        ovr = inter / (areas[i] + areas[order[1:]] - inter)
        inds = np.where(ovr <= iou_thresh)[0]
        order = order[inds + 1]
    return keep


def apply_cross_class_suppression(
    dets: List[Tuple[str, float, np.ndarray, int]], threshold: float = 0.65
) -> List[Tuple[str, float, np.ndarray, int]]:
    """Suppresses duplicate bounding boxes across different classes that heavily overlap."""
    if len(dets) <= 1:
        return dets
    # dets are sorted descending by confidence
    kept = []
    active = [True] * len(dets)
    for i in range(len(dets)):
        if not active[i]:
            continue
        curr = dets[i]
        kept.append(curr)
        for j in range(i + 1, len(dets)):
            if not active[j]:
                continue
            other = dets[j]
            iou = compute_iou(curr[2], other[2])
            if iou >= threshold:
                active[j] = False
    return kept
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


def resolve_dataset_paths(dataset_path: str, split: str = 'val') -> Tuple[str, str]:
    """Resolves image and label directory paths from a YAML file or directory."""
    if os.path.isfile(dataset_path) and (dataset_path.endswith('.yaml') or dataset_path.endswith('.yml')):
        cfg = parse_simple_yaml(dataset_path)
        base = cfg.get('path', '')
        if base and not os.path.isabs(base):
            if os.path.exists(base):
                pass
            else:
                yaml_dir = os.path.dirname(os.path.abspath(dataset_path))
                candidate = os.path.normpath(os.path.join(yaml_dir, base))
                if os.path.exists(candidate):
                    base = candidate

        split_img_rel = cfg.get(split) or cfg.get('val') or cfg.get('images', 'images')
        img_dir = os.path.normpath(os.path.join(base, split_img_rel)) if base else split_img_rel
        lbl_dir = img_dir.replace('images', 'labels')
        if not os.path.exists(lbl_dir) and base:
            candidate_lbl = os.path.normpath(os.path.join(base, 'labels', split))
            if os.path.exists(candidate_lbl):
                lbl_dir = candidate_lbl
        return img_dir, lbl_dir

    # Directory input
    cand_img_split = os.path.join(dataset_path, 'images', split)
    cand_lbl_split = os.path.join(dataset_path, 'labels', split)
    if os.path.isdir(cand_img_split):
        return cand_img_split, cand_lbl_split

    cand_img = os.path.join(dataset_path, 'images')
    cand_lbl = os.path.join(dataset_path, 'labels')
    if os.path.isdir(cand_img):
        return cand_img, cand_lbl

    return dataset_path, os.path.join(dataset_path, 'labels')


class DetectorEvaluator:
    def __init__(
        self,
        model_path: str,
        labels_path: str,
        conf_thresh: float = 0.35,
        iou_nms: float = 0.45,
        iou_cross_class: float = 0.65,
        iou_eval: float = 0.50,
    ):
        self.model_path = model_path
        self.conf_thresh = conf_thresh
        self.iou_nms = iou_nms
        self.iou_cross_class = iou_cross_class
        self.iou_eval = iou_eval

        with open(labels_path, 'r', encoding='utf-8') as f:
            self.labels = [line.strip() for line in f if line.strip()]

        self.relevant_indices = [
            i for i, lbl in enumerate(self.labels) if lbl in RELEVANT_CLASSES
        ]

        self.interpreter = tf.lite.Interpreter(model_path=model_path)
        self.interpreter.allocate_tensors()
        self.inp_details = self.interpreter.get_input_details()[0]
        self.out_details = self.interpreter.get_output_details()[0]
        self.input_shape = self.inp_details['shape']  # [1, 640, 640, 3]

    def predict(
        self, image: np.ndarray
    ) -> Tuple[List[Tuple[str, float, np.ndarray, int]], Dict[str, float]]:
        """Runs inference and postprocessing replicating LocalDetector logic."""
        h0, w0 = image.shape[:2]

        t0 = time.perf_counter()
        lb_img, ratio, (dw, dh) = letterbox(image, (640, 640))
        rgb_img = cv2.cvtColor(lb_img, cv2.COLOR_BGR2RGB)
        input_data = (rgb_img.astype(np.float32) / 255.0)[np.newaxis, ...]
        t_pre = (time.perf_counter() - t0) * 1000.0

        t1 = time.perf_counter()
        self.interpreter.set_tensor(self.inp_details['index'], input_data)
        self.interpreter.invoke()
        raw_output = self.interpreter.get_tensor(self.out_details['index'])
        t_infer = (time.perf_counter() - t1) * 1000.0

        t2 = time.perf_counter()
        # raw_output is [1, 84, 8400]
        batch0 = raw_output[0]  # [84, 8400]
        preds = batch0.T  # [8400, 84]

        boxes = preds[:, :4]
        class_scores = preds[:, 4:]

        candidates = []
        for a in range(8400):
            best_score = 0.0
            best_cls = -1
            for cls_id in self.relevant_indices:
                score = float(class_scores[a, cls_id])
                if score > best_score:
                    best_score = score
                    best_cls = cls_id

            if best_score < self.conf_thresh or best_cls < 0:
                continue

            cx, cy, w, h = boxes[a]
            x1 = max(0.0, min(float(w0), (cx - w / 2.0 - dw) / ratio))
            y1 = max(0.0, min(float(h0), (cy - h / 2.0 - dh) / ratio))
            x2 = max(0.0, min(float(w0), (cx + w / 2.0 - dw) / ratio))
            y2 = max(0.0, min(float(h0), (cy + h / 2.0 - dh) / ratio))

            if x2 > x1 and y2 > y1:
                label = self.labels[best_cls]
                candidates.append((label, best_score, np.array([x1, y1, x2, y2]), best_cls))

        # Per-class NMS
        by_class: Dict[int, List[Tuple[str, float, np.ndarray, int]]] = {}
        for cand in candidates:
            by_class.setdefault(cand[3], []).append(cand)

        nms_survivors = []
        for cls_id, cls_cands in by_class.items():
            b_arr = np.array([c[2] for c in cls_cands])
            s_arr = np.array([c[1] for c in cls_cands])
            keep_indices = nms(b_arr, s_arr, self.iou_nms)
            for ki in keep_indices:
                nms_survivors.append(cls_cands[ki])

        # Global sort descending by confidence
        nms_survivors.sort(key=lambda x: x[1], reverse=True)

        # Cross-class duplicate suppression
        final_dets = apply_cross_class_suppression(nms_survivors, self.iou_cross_class)
        t_post = (time.perf_counter() - t2) * 1000.0

        latencies = {
            'pre_ms': t_pre,
            'infer_ms': t_infer,
            'post_ms': t_post,
            'total_ms': t_pre + t_infer + t_post,
        }
        return final_dets, latencies

    def evaluate_dataset(
        self, dataset_dir: str, split: str = 'val'
    ) -> Dict:
        """Evaluates model across labeled dataset and produces detailed metrics."""
        img_dir, lbl_dir = resolve_dataset_paths(dataset_dir, split)

        if not os.path.isdir(img_dir):
            raise FileNotFoundError(f"Images directory not found: {img_dir}")

        image_files = [
            f for f in sorted(os.listdir(img_dir))
            if f.lower().endswith(('.jpg', '.jpeg', '.png'))
        ]

        if not image_files:
            return {
                'status': 'empty_dataset',
                'message': f'No images found in {img_dir}',
                'image_count': 0,
            }

        class_stats = {
            cls: {'tp': 0, 'fp': 0, 'fn': 0, 'gt': 0, 'duplicates': 0}
            for cls in RELEVANT_CLASSES
        }

        total_gt = 0
        total_tp = 0
        total_fp = 0
        total_fn = 0
        total_duplicates = 0

        image_reports = []
        latencies = []

        # Warmup
        dummy = np.zeros((640, 640, 3), dtype=np.uint8)
        self.predict(dummy)

        for img_name in image_files:
            img_path = os.path.join(img_dir, img_name)
            img = cv2.imread(img_path)
            if img is None:
                continue

            h0, w0 = img.shape[:2]

            # Parse Ground Truth
            gt_boxes: List[Tuple[str, np.ndarray]] = []
            lbl_name = os.path.splitext(img_name)[0] + '.txt'
            lbl_path = os.path.join(lbl_dir, lbl_name)

            if os.path.exists(lbl_path):
                with open(lbl_path, 'r', encoding='utf-8') as f:
                    for line in f:
                        parts = line.strip().split()
                        if len(parts) >= 5:
                            cls_idx = int(parts[0])
                            label = self.labels[cls_idx] if cls_idx < len(self.labels) else f"class_{cls_idx}"
                            if label not in RELEVANT_CLASSES:
                                continue
                            cx = float(parts[1]) * w0
                            cy = float(parts[2]) * h0
                            bw = float(parts[3]) * w0
                            bh = float(parts[4]) * h0
                            x1 = max(0.0, cx - bw / 2.0)
                            y1 = max(0.0, cy - bh / 2.0)
                            x2 = min(float(w0), cx + bw / 2.0)
                            y2 = min(float(h0), cy + bh / 2.0)
                            gt_boxes.append((label, np.array([x1, y1, x2, y2])))

            for label, _ in gt_boxes:
                class_stats[label]['gt'] += 1
                total_gt += 1

            # Run Model Prediction
            predictions, lat = self.predict(img)
            latencies.append(lat)

            # Match Predictions to Ground Truth
            gt_matched = [False] * len(gt_boxes)
            pred_matched = [False] * len(predictions)

            img_duplicates = 0
            img_tp = 0
            img_fp = 0

            # Match highest confidence predictions first
            for p_idx, (p_label, p_conf, p_box, _) in enumerate(predictions):
                best_iou = 0.0
                best_gt_idx = -1

                for g_idx, (g_label, g_box) in enumerate(gt_boxes):
                    if p_label != g_label:
                        continue
                    iou = compute_iou(p_box, g_box)
                    if iou > best_iou:
                        best_iou = iou
                        best_gt_idx = g_idx

                if best_iou >= self.iou_eval and best_gt_idx >= 0:
                    if not gt_matched[best_gt_idx]:
                        # First valid match -> True Positive
                        gt_matched[best_gt_idx] = True
                        pred_matched[p_idx] = True
                        class_stats[p_label]['tp'] += 1
                        img_tp += 1
                    else:
                        # Second prediction matching the same GT box -> Duplicate Detection!
                        pred_matched[p_idx] = True
                        class_stats[p_label]['duplicates'] += 1
                        img_duplicates += 1
                        total_duplicates += 1
                else:
                    # Unmatched prediction -> False Positive
                    class_stats[p_label]['fp'] += 1
                    img_fp += 1

            # Ground truth boxes that were never predicted -> False Negatives
            img_fn = 0
            for g_idx, matched in enumerate(gt_matched):
                if not matched:
                    g_label, _ = gt_boxes[g_idx]
                    class_stats[g_label]['fn'] += 1
                    img_fn += 1

            total_tp += img_tp
            total_fp += img_fp
            total_fn += img_fn

            image_reports.append({
                'image': img_name,
                'dimensions': [w0, h0],
                'ground_truth_count': len(gt_boxes),
                'prediction_count': len(predictions),
                'true_positives': img_tp,
                'false_positives': img_fp,
                'missed_obstacles': img_fn,
                'duplicate_detections': img_duplicates,
                'latencies_ms': lat,
            })

        # Calculate Overall Metrics
        precision = total_tp / (total_tp + total_fp) if (total_tp + total_fp) > 0 else 0.0
        recall = total_tp / (total_tp + total_fn) if (total_tp + total_fn) > 0 else 0.0
        f1 = (2 * precision * recall) / (precision + recall) if (precision + recall) > 0 else 0.0

        # Per-Class Metrics
        per_class_metrics = {}
        for cls, s in class_stats.items():
            if s['gt'] == 0 and s['fp'] == 0:
                continue
            p = s['tp'] / (s['tp'] + s['fp']) if (s['tp'] + s['fp']) > 0 else 0.0
            r = s['tp'] / (s['tp'] + s['fn']) if (s['tp'] + s['fn']) > 0 else 0.0
            f1_cls = (2 * p * r) / (p + r) if (p + r) > 0 else 0.0
            per_class_metrics[cls] = {
                'ground_truth': s['gt'],
                'tp': s['tp'],
                'fp': s['fp'],
                'fn': s['fn'],
                'duplicates': s['duplicates'],
                'precision': round(p, 4),
                'recall': round(r, 4),
                'f1': round(f1_cls, 4),
            }

        mean_infer_ms = np.mean([l['infer_ms'] for l in latencies]) if latencies else 0.0
        mean_total_ms = np.mean([l['total_ms'] for l in latencies]) if latencies else 0.0
        mean_fps = 1000.0 / mean_total_ms if mean_total_ms > 0 else 0.0

        return {
            'status': 'success',
            'model': self.model_path,
            'confidence_threshold': self.conf_thresh,
            'iou_nms_threshold': self.iou_nms,
            'iou_cross_class_threshold': self.iou_cross_class,
            'iou_eval_threshold': self.iou_eval,
            'summary': {
                'images_evaluated': len(image_files),
                'ground_truth_objects': total_gt,
                'true_positives': total_tp,
                'false_positives': total_fp,
                'missed_detections': total_fn,
                'duplicate_detections': total_duplicates,
                'precision': round(precision, 4),
                'recall': round(recall, 4),
                'f1': round(f1, 4),
                'mean_infer_latency_ms': round(float(mean_infer_ms), 2),
                'mean_total_latency_ms': round(float(mean_total_ms), 2),
                'mean_fps': round(float(mean_fps), 1),
            },
            'per_class': per_class_metrics,
            'image_reports': image_reports,
        }


def print_summary_table(results: Dict):
    """Prints a clean ASCII summary table to stdout."""
    s = results['summary']
    print("\n" + "=" * 70)
    print(f"  MODEL EVALUATION REPORT: {os.path.basename(results['model'])}")
    print("=" * 70)
    print(f"  Images Evaluated:       {s['images_evaluated']}")
    print(f"  Confidence Threshold:   {results['confidence_threshold']}")
    print(f"  Eval IoU Threshold:     {results['iou_eval_threshold']}")
    print("-" * 70)
    print(f"  Total Ground Truth:     {s['ground_truth_objects']}")
    print(f"  True Positives (TP):    {s['true_positives']}")
    print(f"  False Positives (FP):   {s['false_positives']}")
    print(f"  Missed Obstacles (FN):  {s['missed_detections']}")
    print(f"  Duplicate Detections:   {s['duplicate_detections']}")
    print("-" * 70)
    print(f"  PRECISION:              {s['precision'] * 100:.1f}%")
    print(f"  RECALL:                 {s['recall'] * 100:.1f}%")
    print(f"  F1-SCORE:               {s['f1'] * 100:.1f}%")
    print("-" * 70)
    print(f"  Mean Inference Latency: {s['mean_infer_latency_ms']:.1f} ms")
    print(f"  Mean Total Latency:     {s['mean_total_latency_ms']:.1f} ms ({s['mean_fps']:.1f} FPS)")
    print("=" * 70)

    if results['per_class']:
        print(f"\n  {'Class':<16} {'GT':<5} {'TP':<5} {'FP':<5} {'FN':<5} {'Dup':<5} {'Precision':<10} {'Recall':<10} {'F1':<10}")
        print("  " + "-" * 68)
        for cls, m in sorted(results['per_class'].items(), key=lambda x: x[1]['ground_truth'], reverse=True):
            print(
                f"  {cls:<16} {m['ground_truth']:<5} {m['tp']:<5} {m['fp']:<5} {m['fn']:<5} {m['duplicates']:<5} "
                f"{m['precision']*100:>8.1f}% {m['recall']*100:>8.1f}% {m['f1']*100:>8.1f}%"
            )
        print("=" * 70 + "\n")


def main():
    parser = argparse.ArgumentParser(description="Evaluate on-device YOLO TFLite detector.")
    parser.add_argument(
        '--model',
        default='frontend/assets/models/yolo11n_float16.tflite',
        help='Path to .tflite model file',
    )
    parser.add_argument(
        '--labels',
        default='frontend/assets/models/labels.txt',
        help='Path to labels.txt',
    )
    parser.add_argument(
        '--dataset',
        '--data',
        dest='dataset',
        default='backend/evaluation_dataset',
        help='Path to dataset directory or dataset.yaml file',
    )
    parser.add_argument(
        '--split',
        default='val',
        choices=['train', 'val', 'test', 'all'],
        help='Split partition to evaluate (default: val)',
    )
    parser.add_argument(
        '--conf',
        type=float,
        default=0.35,
        help='Confidence threshold (default: 0.35)',
    )
    parser.add_argument(
        '--iou-nms',
        type=float,
        default=0.45,
        help='NMS IoU threshold (default: 0.45)',
    )
    parser.add_argument(
        '--iou-cross-class',
        type=float,
        default=0.65,
        help='Cross-class duplicate suppression IoU threshold (default: 0.65)',
    )
    parser.add_argument(
        '--iou-eval',
        type=float,
        default=0.50,
        help='Evaluation matching IoU threshold (default: 0.50)',
    )
    parser.add_argument(
        '--output',
        default='backend/evaluation_report.json',
        help='Path to save JSON evaluation report',
    )

    args = parser.parse_args()

    evaluator = DetectorEvaluator(
        model_path=args.model,
        labels_path=args.labels,
        conf_thresh=args.conf,
        iou_nms=args.iou_nms,
        iou_cross_class=args.iou_cross_class,
        iou_eval=args.iou_eval,
    )

    results = evaluator.evaluate_dataset(args.dataset, split=args.split)

    if results.get('status') == 'empty_dataset':
        print(f"Warning: {results['message']}")
        sys.exit(0)

    print_summary_table(results)

    with open(args.output, 'w', encoding='utf-8') as f:
        json.dump(results, f, indent=2)
    print(f"Saved detailed evaluation report to {args.output}")


if __name__ == '__main__':
    main()
