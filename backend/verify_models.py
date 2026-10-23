import numpy as np
import tensorflow as tf
from ultralytics import YOLO
from ultralytics.utils import ASSETS
import os
import cv2

def letterbox(im, new_shape=(640, 640), color=(114, 114, 114)):
    shape = im.shape[:2] # [h, w]
    r = min(new_shape[0] / shape[0], new_shape[1] / shape[1])
    new_unpad = (int(round(shape[1] * r)), int(round(shape[0] * r)))
    dw, dh = new_shape[1] - new_unpad[0], new_shape[0] - new_unpad[1]
    dw /= 2
    dh /= 2
    if shape[::-1] != new_unpad:
        im = cv2.resize(im, new_unpad, interpolation=cv2.INTER_LINEAR)
    top, bottom = int(round(dh - 0.1)), int(round(dh + 0.1))
    left, right = int(round(dw - 0.1)), int(round(dw + 0.1))
    im = cv2.copyMakeBorder(im, top, bottom, left, right, cv2.BORDER_CONSTANT, value=color)
    return im, r, (dw, dh)

def nms(boxes, scores, iou_threshold=0.45):
    # boxes: [N, 4] in (x1, y1, x2, y2)
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
        inds = np.where(ovr <= iou_threshold)[0]
        order = order[inds + 1]
    return keep

def verify():
    bus_path = os.path.join(ASSETS, "bus.jpg")
    print(f"Testing on image: {bus_path}")
    orig_img = cv2.imread(bus_path)
    h0, w0 = orig_img.shape[:2]
    
    # 1. PyTorch inference
    print("\n--- Running PyTorch YOLO11n ---")
    yolo_pt = YOLO("yolo11n.pt")
    pt_res = yolo_pt(bus_path, conf=0.25, iou=0.45, verbose=False)[0]
    print(f"PyTorch detections count: {len(pt_res.boxes)}")
    pt_dets = []
    for box in pt_res.boxes:
        cls_id = int(box.cls[0])
        conf = float(box.conf[0])
        xyxy = box.xyxy[0].cpu().numpy()
        name = yolo_pt.names[cls_id]
        pt_dets.append((name, conf, xyxy))
        print(f"  PyTorch: {name:15s} conf={conf:.3f} box=[{xyxy[0]:.1f}, {xyxy[1]:.1f}, {xyxy[2]:.1f}, {xyxy[3]:.1f}]")

    # 2. TFLite FP32 and FP16 inference
    for model_name, path in [
        ("TFLite FP32", "yolo11n_tflite/yolo11n_float32.tflite"),
        ("TFLite FP16", "yolo11n_tflite/yolo11n_float16.tflite")
    ]:
        print(f"\n--- Running {model_name} ({path}) ---")
        interpreter = tf.lite.Interpreter(model_path=path)
        interpreter.allocate_tensors()
        
        inp_details = interpreter.get_input_details()[0]
        out_details = interpreter.get_output_details()[0]
        
        # Preprocessing: letterbox to 640x640, BGR -> RGB, float32 [0, 1]
        lb_img, ratio, (dw, dh) = letterbox(orig_img, (640, 640))
        rgb_img = cv2.cvtColor(lb_img, cv2.COLOR_BGR2RGB)
        input_data = (rgb_img.astype(np.float32) / 255.0)[np.newaxis, ...]
        
        interpreter.set_tensor(inp_details['index'], input_data)
        interpreter.invoke()
        
        raw_output = interpreter.get_tensor(out_details['index']) # [1, 84, 8400]
        # Transpose to [8400, 84]
        preds = raw_output[0].T # (8400, 84)
        
        boxes = preds[:, :4] # cx, cy, w, h in 640x640 coordinates
        class_scores = preds[:, 4:] # (8400, 80)
        
        max_scores = np.max(class_scores, axis=1)
        class_ids = np.argmax(class_scores, axis=1)
        
        mask = max_scores >= 0.25
        filt_boxes = boxes[mask]
        filt_scores = max_scores[mask]
        filt_classes = class_ids[mask]
        
        # Convert cx, cy, w, h in 640x640 to x1, y1, x2, y2 in original image coordinates
        final_boxes = []
        for b in filt_boxes:
            cx, cy, w, h = b
            x1 = cx - w / 2
            y1 = cy - h / 2
            x2 = cx + w / 2
            y2 = cy + h / 2
            # Map back removing padding and scale
            x1 = (x1 - dw) / ratio
            x2 = (x2 - dw) / ratio
            y1 = (y1 - dh) / ratio
            y2 = (y2 - dh) / ratio
            # Clip
            x1 = max(0, min(w0, x1))
            x2 = max(0, min(w0, x2))
            y1 = max(0, min(h0, y1))
            y2 = max(0, min(h0, y2))
            final_boxes.append([x1, y1, x2, y2])
            
        final_boxes = np.array(final_boxes) if len(final_boxes) > 0 else np.zeros((0, 4))
        
        # Apply per-class NMS
        tf_dets = []
        for c in np.unique(filt_classes):
            c_mask = filt_classes == c
            c_boxes = final_boxes[c_mask]
            c_scores = filt_scores[c_mask]
            keep_indices = nms(c_boxes, c_scores, iou_threshold=0.45)
            for ki in keep_indices:
                name = yolo_pt.names[c]
                conf = c_scores[ki]
                box = c_boxes[ki]
                tf_dets.append((name, conf, box))
                
        print(f"{model_name} detections count: {len(tf_dets)}")
        # Sort by confidence descending
        tf_dets.sort(key=lambda x: x[1], reverse=True)
        for name, conf, box in tf_dets:
            print(f"  {model_name}: {name:15s} conf={conf:.3f} box=[{box[0]:.1f}, {box[1]:.1f}, {box[2]:.1f}, {box[3]:.1f}]")

if __name__ == "__main__":
    verify()
