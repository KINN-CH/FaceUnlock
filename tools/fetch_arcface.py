#!/usr/bin/env python3
"""
ArcFace 얼굴 임베딩 모델을 내려받아 CoreML(.mlpackage)로 변환한다.

왜 저장소에 모델을 넣지 않는가:
    InsightFace 사전학습 가중치는 비상업 연구용 라이선스다. 재배포하지 않고
    각자 원본 배포처에서 받도록 한다.

사용법:
    make model          # venv 생성 → 의존성 설치 → 변환까지 한 번에

    직접 하려면 (coremltools 는 Python 3.14 를 아직 지원하지 않는다 — 3.11/3.12 필요):
        /opt/homebrew/opt/python@3.11/bin/python3.11 -m venv .venv
        .venv/bin/pip install torch onnx onnx2torch coremltools numpy pillow
        .venv/bin/python tools/fetch_arcface.py

    변환이 끝나면 .venv 는 지워도 앱 동작에는 영향이 없다 (빌드 타임 도구일 뿐).

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


def build_one(onnx_path: Path, precision_name: str, out_path: Path) -> float:
    """한 가지 정밀도로 변환해 저장하고, PyTorch 출력과의 코사인 유사도를 돌려준다.

    **반드시 별도 프로세스에서 호출해야 한다.** 한 프로세스에서 ct.convert 를 두 번
    부르면 coremltools 의 fp16 패스가 GIL 을 놓친 채로 죽는다 (torch 2.13 조합).
    """
    import numpy as np
    import torch
    import coremltools as ct
    from onnx2torch import convert as onnx_to_torch

    model = onnx_to_torch(str(onnx_path)).eval()

    # 프로세스가 달라도 같은 입력이 나와야 비교가 성립한다.
    # 실제 입력 분포와 비슷하게: 정규화 후 픽셀은 대략 [-1, 1] 범위다.
    torch.manual_seed(0)
    example = torch.rand(*INPUT_SHAPE) * 2 - 1
    with torch.no_grad():
        ref = model(example).detach().numpy().reshape(-1)
    if ref.shape[-1] != EMBED_DIM:
        raise SystemExit(f"임베딩 차원이 {EMBED_DIM} 이 아닙니다: {ref.shape}")

    traced = torch.jit.trace(model, example, strict=False)
    precision = getattr(ct.precision, precision_name)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="input", shape=INPUT_SHAPE, dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = (
        f"ArcFace (InsightFace buffalo_l / w600k_r50), {precision_name}. "
        "Input: (RGB - 127.5) / 127.5, NCHW 1x3x112x112. Output: 512-d embedding."
    )
    if out_path.exists():
        shutil.rmtree(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out_path))

    got = np.asarray(mlmodel.predict({"input": example.numpy()})["embedding"]).reshape(-1)
    return float(ref @ got / (np.linalg.norm(ref) * np.linalg.norm(got)))


def build_in_subprocess(onnx_path: Path, precision_name: str) -> tuple[Path, float]:
    import math
    import subprocess

    out_path = CACHE / f"ArcFace-{precision_name}.mlpackage"
    log(f"CoreML 변환 중 ({precision_name})… 몇 분 걸릴 수 있습니다")

    result = subprocess.run(
        [sys.executable, __file__, "--build", precision_name, str(onnx_path), str(out_path)],
        capture_output=True, text=True,
    )
    marker = "COSINE="
    line = next((l for l in result.stdout.splitlines() if l.startswith(marker)), None)
    if line is None:
        sys.stderr.write(result.stdout[-2000:])
        sys.stderr.write(result.stderr[-2000:])
        raise SystemExit(f"{precision_name} 변환 실패 (종료 코드 {result.returncode})")

    cos = float(line[len(marker):])
    angle = math.degrees(math.acos(min(1.0, cos)))
    log(f"  {precision_name}: cos={cos:.6f}  (임베딩 편차 {angle:.2f}°)")
    return out_path, cos


def convert(onnx_path: Path) -> None:
    # 1단계 — FLOAT32 로 **구조적 정확성**을 확인한다.
    #   레이어 누락·transpose 실수 같은 진짜 변환 버그는 여기서 cos 가 0 근처로 떨어진다.
    #   양자화 오차가 섞이지 않으므로 기준을 아주 빡빡하게 잡을 수 있다.
    fp32_path, cos32 = build_in_subprocess(onnx_path, "FLOAT32")
    if cos32 < 0.9999:
        raise SystemExit(
            f"변환이 구조적으로 잘못되었습니다 (FLOAT32 cos={cos32:.6f}).\n"
            "onnx2torch / coremltools 버전을 확인하세요."
        )
    log("✅ 구조 검증 통과 — 변환된 그래프가 원본과 동일합니다")

    # 2단계 — FLOAT16 은 **얼마나 손해인지**만 본다.
    #   Apple Neural Engine 은 어차피 내부적으로 FP16 으로 돈다. 등록과 인증이 같은
    #   모델을 쓰므로 양자화 편향은 양쪽에서 상쇄된다. 문제는 편차가 판정 여유
    #   (임계 0.48 ≈ 61°) 를 갉아먹을 만큼 큰가인데, 몇 도 수준이면 무시할 만하다.
    FP16_MIN = 0.995   # ≈ 5.7°. 61° 의 판정 여유에 비하면 미미하다.
    try:
        fp16_path, cos16 = build_in_subprocess(onnx_path, "FLOAT16")
    except SystemExit as exc:
        log(f"FLOAT16 변환 실패 ({exc}) — FLOAT32 를 씁니다")
        fp16_path, cos16 = None, 0.0

    if fp16_path is not None and cos16 >= FP16_MIN:
        chosen, label = fp16_path, "FLOAT16"
        log("FLOAT16 채택 — Neural Engine 에서 가장 빠르고 편차도 무시할 수준입니다")
    else:
        chosen, label = fp32_path, "FLOAT32"
        log("FLOAT32 채택 — 정확하지만 FLOAT16 보다 느리고 큽니다")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(chosen, OUT)

    size = sum(f.stat().st_size for f in OUT.rglob("*") if f.is_file())
    log(f"저장됨: {OUT} ({size / 1e6:.1f} MB, {label})")


def main() -> None:
    # 서브프로세스 모드: 한 정밀도만 변환하고 결과를 stdout 으로 알린다.
    if len(sys.argv) > 1 and sys.argv[1] == "--build":
        _, _, precision_name, onnx, out = sys.argv
        cos = build_one(Path(onnx), precision_name, Path(out))
        print(f"COSINE={cos:.8f}")
        return

    CACHE.mkdir(parents=True, exist_ok=True)
    zip_path = download(PACK_URL, CACHE / PACK_NAME)
    onnx_path = extract_onnx(zip_path)
    convert(onnx_path)
    print()
    log("다음 단계: `make debug` 로 앱을 다시 빌드하면 모델이 번들에 포함됩니다.")


if __name__ == "__main__":
    main()
