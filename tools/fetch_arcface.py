#!/usr/bin/env python3
"""
ArcFace 얼굴 임베딩 모델을 내려받아 CoreML(.mlpackage)로 변환한다.

왜 저장소에 모델을 넣지 않는가:
    InsightFace 사전학습 가중치는 비상업 연구용 라이선스다. 재배포하지 않고
    각자 원본 배포처에서 받도록 한다.

사용법:
    python3 -m venv .venv && source .venv/bin/activate
    pip install torch onnx onnx2torch coremltools numpy pillow
    python3 tools/fetch_arcface.py

결과:
    Resources/Models/ArcFace.mlpackage
        입력  input   MultiArray (1, 3, 112, 112) float32
                      값은 (RGB픽셀 - 127.5) / 127.5 로 정규화되어 있어야 한다
                      (정규화는 Swift 쪽 FaceAligner 가 수행한다)
        출력  embedding  MultiArray (1, 512) float32  — L2 정규화 전 raw 임베딩
"""

from __future__ import annotations

import hashlib
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "build" / "model-cache"
OUT_DIR = ROOT / "Resources" / "Models"
OUT = OUT_DIR / "ArcFace.mlpackage"

# InsightFace 공식 릴리스의 buffalo_l 팩. 안에 w600k_r50.onnx(ResNet50 ArcFace)가 들어 있다.
PACK_URL = "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip"
PACK_NAME = "buffalo_l.zip"
ONNX_MEMBER = "w600k_r50.onnx"

INPUT_SHAPE = (1, 3, 112, 112)
EMBED_DIM = 512


def log(msg: str) -> None:
    print(f"[fetch_arcface] {msg}", flush=True)


def download(url: str, dest: Path) -> Path:
    if dest.exists() and dest.stat().st_size > 0:
        log(f"캐시 사용: {dest} ({dest.stat().st_size / 1e6:.1f} MB)")
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    log(f"내려받는 중: {url}")
    tmp = dest.with_suffix(dest.suffix + ".part")

    def hook(blocks, block_size, total):
        if total > 0:
            pct = min(100, blocks * block_size * 100 // total)
            print(f"\r  {pct:3d}%  ({total / 1e6:.0f} MB)", end="", file=sys.stderr)

    urllib.request.urlretrieve(url, tmp, reporthook=hook)
    print(file=sys.stderr)
    tmp.rename(dest)
    log(f"완료: {dest} ({dest.stat().st_size / 1e6:.1f} MB)")
    return dest


def extract_onnx(zip_path: Path) -> Path:
    onnx_path = CACHE / ONNX_MEMBER
    if onnx_path.exists():
        log(f"캐시 사용: {onnx_path}")
        return onnx_path
    with zipfile.ZipFile(zip_path) as zf:
        member = next((n for n in zf.namelist() if n.endswith(ONNX_MEMBER)), None)
        if member is None:
            raise SystemExit(f"{PACK_NAME} 안에서 {ONNX_MEMBER} 를 찾지 못했습니다: {zf.namelist()}")
        log(f"압축 해제: {member}")
        with zf.open(member) as src, open(onnx_path, "wb") as dst:
            shutil.copyfileobj(src, dst)
    digest = hashlib.sha256(onnx_path.read_bytes()).hexdigest()[:16]
    log(f"ONNX 준비됨 ({onnx_path.stat().st_size / 1e6:.1f} MB, sha256:{digest}…)")
    return onnx_path


def convert(onnx_path: Path) -> None:
    # coremltools 6+ 는 ONNX 를 직접 못 읽는다. onnx2torch 로 PyTorch 모듈로 바꾼 뒤
    # TorchScript 로 trace 해서 변환한다.
    import numpy as np
    import torch
    import coremltools as ct
    from onnx2torch import convert as onnx_to_torch

    log("ONNX → PyTorch 변환 중…")
    model = onnx_to_torch(str(onnx_path)).eval()

    example = torch.randn(*INPUT_SHAPE)
    with torch.no_grad():
        ref = model(example)
    ref = ref.detach().numpy()
    if ref.shape[-1] != EMBED_DIM:
        raise SystemExit(f"임베딩 차원이 {EMBED_DIM} 이 아닙니다: {ref.shape}")
    log(f"PyTorch 출력 확인: {ref.shape}")

    log("TorchScript trace 중…")
    traced = torch.jit.trace(model, example, strict=False)

    log("CoreML 변환 중… (몇 분 걸릴 수 있습니다)")
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="input", shape=INPUT_SHAPE, dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = (
        "ArcFace (InsightFace buffalo_l / w600k_r50). "
        "Input: (RGB - 127.5) / 127.5, NCHW 1x3x112x112. Output: 512-d embedding."
    )

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if OUT.exists():
        shutil.rmtree(OUT)
    mlmodel.save(str(OUT))
    log(f"저장됨: {OUT}")

    # 변환이 수치적으로 맞는지 확인한다. 여기서 어긋나면 인식이 통째로 무의미해진다.
    log("CoreML 출력과 PyTorch 출력 대조 중…")
    got = mlmodel.predict({"input": example.numpy()})["embedding"]
    a = ref.reshape(-1)
    b = np.asarray(got).reshape(-1)
    cos = float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))
    log(f"코사인 유사도(PyTorch vs CoreML) = {cos:.6f}")
    if cos < 0.999:
        raise SystemExit(f"변환 오차가 큽니다 (cos={cos:.6f}). FLOAT32 로 재시도해 보세요.")
    log("✅ 변환 검증 통과")


def main() -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    zip_path = download(PACK_URL, CACHE / PACK_NAME)
    onnx_path = extract_onnx(zip_path)
    convert(onnx_path)
    print()
    log("다음 단계: `make debug` 로 앱을 다시 빌드하면 모델이 번들에 포함됩니다.")


if __name__ == "__main__":
    main()
