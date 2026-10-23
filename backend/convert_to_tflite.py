import os
import io
import numpy as np

# Patch np.load globally to allow pickle
_orig_load = np.load
def _safe_load(*args, **kwargs):
    kwargs["allow_pickle"] = True
    return _orig_load(*args, **kwargs)
np.load = _safe_load

import onnx2tf
import onnx2tf.onnx2tf as otf_module
import onnx2tf.utils.common_functions as cf

dummy_func = lambda: np.zeros((1, 480, 640, 3), dtype=np.float32)
cf.download_test_image_data = dummy_func
otf_module.download_test_image_data = dummy_func

print("Starting onnx2tf conversion for yolo11n.onnx with output_signaturedefs=True...")
onnx2tf.convert(
    input_onnx_file_path="yolo11n.onnx",
    output_folder_path="yolo11n_tflite",
    output_signaturedefs=True,
    copy_onnx_input_output_names_to_tflite=True,
    check_onnx_tf_outputs_elementwise_close=False,
    not_use_onnxsim=True,
    non_verbose=True,
)
print("Conversion completed successfully!")
