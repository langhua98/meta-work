"""把图片转成测试程序读的格式：int32 宽、int32 高、BGR 字节、NV21 字节（宽高取偶数）。
用法：python3 make_inputs.py 输出目录 图片...
NV21 用安卓相机的算法（BT.601 全范围，和 YuvImage/Camera 一样），这样测的就是手机上真正送进模型的数据。"""
import struct, sys, os
import numpy as np
from PIL import Image

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for path in sys.argv[2:]:
    im = Image.open(path).convert("RGB")
    w, h = im.size[0] // 2 * 2, im.size[1] // 2 * 2
    rgb = np.asarray(im, dtype=np.float32)[:h, :w]
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    y = 0.299 * r + 0.587 * g + 0.114 * b
    u = -0.169 * r - 0.331 * g + 0.5 * b + 128
    v = 0.5 * r - 0.419 * g - 0.081 * b + 128
    sub = lambda a: a.reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3))
    vu = np.stack([sub(v), sub(u)], axis=-1)            # NV21：先 V 后 U
    clip = lambda a: np.clip(np.rint(a), 0, 255).astype(np.uint8)
    bgr = clip(rgb[..., ::-1])
    name = os.path.splitext(os.path.basename(path))[0]
    with open(os.path.join(out, name + ".raw"), "wb") as f:
        f.write(struct.pack("<ii", w, h))
        f.write(bgr.tobytes())
        f.write(clip(y).tobytes())
        f.write(clip(vu).tobytes())
    print(name, w, h)
