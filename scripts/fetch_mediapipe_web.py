"""Baixa o MediaPipe para navegador e o modelo do rosto, com conferência.

O aplicativo web roda o MediaPipe Face Landmarker no próprio aparelho, como o
Android. Os arquivos (cerca de 30 MB) não vão no repositório: este script os
baixa em ``mobile/eyelearn_app/web/mediapipe/``, de onde o site os serve. Nada
é carregado de CDN de terceiros quando a família abre o aplicativo -- o
navegador só fala com o endereço do próprio site.

Versões fixas e conferidas por SHA-256: uma atualização silenciosa do modelo
mudaria os pontos do rosto e, com eles, a calibração.

Uso::

    python scripts/fetch_mediapipe_web.py
"""

from __future__ import annotations

import hashlib
import io
import sys
import tarfile
import urllib.request
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
TARGET = REPOSITORY_ROOT / "mobile" / "eyelearn_app" / "web" / "mediapipe"

TASKS_VISION_VERSION = "1.1.1"
TASKS_VISION_URL = (
    "https://registry.npmjs.org/@mediapipe/tasks-vision/-/"
    f"tasks-vision-{TASKS_VISION_VERSION}.tgz"
)
TASKS_VISION_SHA256 = "fbbea455a8b50c31c39092027b3548336de198bfcdbaf75cc08245e773011b8f"

MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/face_landmarker/"
    "face_landmarker/float16/1/face_landmarker.task"
)
MODEL_SHA256 = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"

#: O que se tira do pacote npm. As duas variantes do WebAssembly: a com SIMD,
#: que o Safari tem desde o iOS 16.4, e a sem, para aparelho mais velho.
WANTED = {
    "package/vision_bundle.mjs": "vision_bundle.mjs",
    "package/wasm/vision_wasm_internal.js": "wasm/vision_wasm_internal.js",
    "package/wasm/vision_wasm_internal.wasm": "wasm/vision_wasm_internal.wasm",
    "package/wasm/vision_wasm_nosimd_internal.js": "wasm/vision_wasm_nosimd_internal.js",
    "package/wasm/vision_wasm_nosimd_internal.wasm": "wasm/vision_wasm_nosimd_internal.wasm",
    "package/LICENSE": "LICENSE",
}


def download(url: str, sha256: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != sha256:
        raise SystemExit(f"checksum não confere para {url}: {digest}")
    return data


def main() -> int:
    TARGET.mkdir(parents=True, exist_ok=True)
    (TARGET / "wasm").mkdir(exist_ok=True)

    found = set()
    tarball = io.BytesIO(download(TASKS_VISION_URL, TASKS_VISION_SHA256))
    with tarfile.open(fileobj=tarball) as archive:
        for member in archive.getmembers():
            # Só os nomes listados, e só arquivos regulares: nada de caminho
            # vindo do pacote decide onde se escreve.
            if member.name in WANTED and member.isfile():
                data = archive.extractfile(member).read()
                (TARGET / WANTED[member.name]).write_bytes(data)
                found.add(member.name)
    missing = set(WANTED) - found - {"package/LICENSE"}
    if missing:
        raise SystemExit(f"faltaram no pacote: {sorted(missing)}")

    (TARGET / "face_landmarker.task").write_bytes(download(MODEL_URL, MODEL_SHA256))

    total = sum(f.stat().st_size for f in TARGET.rglob("*") if f.is_file())
    print(f"MediaPipe {TASKS_VISION_VERSION} e modelo em {TARGET} ({total / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
