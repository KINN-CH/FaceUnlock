#!/usr/bin/env python3
"""Swift 전처리가 원본 ONNX 와 같은 임베딩을 내는지 확인한다.

CoreML 은 채널 순서(RGB↔BGR)나 배치(NCHW↔NHWC)를 틀려도 에러를 내지 않는다.
그냥 조용히 다른 벡터가 나올 뿐이고, 실사용에서는 "얼굴은 잡히는데 절대 일치하지
않는" 증상으로만 드러난다. 그래서 고정 입력 하나를 양쪽에 똑같이 먹여 대조한다.

기대치: 코사인 > 0.99 (FP16 양자화 오차만 남는다)
        RGB/BGR 뒤바뀜 → 0.3~0.5,  NCHW/NHWC 뒤바뀜 → 0 근처
"""
import sys
from pathlib import Path
import numpy as np
import torch
from onnx2torch import convert

ROOT = Path(__file__).resolve().parent.parent
ONNX = ROOT / "build" / "model-cache" / "w600k_r50.onnx"
SWIFT_OUT = ROOT / "build" / "swift_embed.txt"
S = 112
MIN_COSINE = 0.99


def fixture() -> np.ndarray:
    """Tools/AlignTest/SelfTest.swift 의 PreprocessFixture 와 같은 패턴."""
    rgba = np.zeros((S, S, 4), dtype=np.uint8)
    xs = np.arange(S)[None, :]
    ys = np.arange(S)[:, None]
    rgba[..., 0] = (xs * 7 + ys * 13) % 256
    rgba[..., 1] = (xs * 3 + ys * 29 + 11) % 256
    rgba[..., 2] = (xs * 17 + ys * 5 + 200) % 256
    rgba[..., 3] = 255
    return rgba


def main() -> int:
    if not ONNX.exists():
        sys.exit(f"원본 ONNX 가 없습니다: {ONNX}\n먼저 `make model` 을 실행하세요.")
    if not SWIFT_OUT.exists():
        sys.exit(f"Swift 결과가 없습니다: {SWIFT_OUT}\n`make xcheck` 로 실행하세요.")

    rgba = fixture()
    # Swift 의 EmbeddingModel.fillInput 과 같은 변환.
    chw = rgba[..., :3].astype(np.float32).transpose(2, 0, 1)
    inp = torch.from_numpy(((chw - 127.5) / 127.5)[None, ...])

    model = convert(str(ONNX)).eval()
    with torch.no_grad():
        ref = model(inp).numpy().reshape(-1)
    ref /= np.linalg.norm(ref)

    got = np.array([float(v) for v in SWIFT_OUT.read_text().strip().split(",")])
    if got.shape != ref.shape:
        sys.exit(f"차원 불일치: ONNX {ref.shape} vs Swift {got.shape}")

    cos = float(ref @ got)
    angle = np.degrees(np.arccos(min(1.0, cos)))
    print(f"[verify] ONNX(원본) vs Swift+CoreML  코사인 = {cos:.6f}  (편차 {angle:.2f}°)")

    if cos < MIN_COSINE:
        print(f"[verify] ❌ 기준({MIN_COSINE}) 미달 — 채널 순서나 배치가 어긋났을 수 있습니다")
        return 1
    print("[verify] ✅ 전처리 일치 — 채널 순서·NCHW 배치·정규화 모두 정상")
    return 0


if __name__ == "__main__":
    sys.exit(main())
