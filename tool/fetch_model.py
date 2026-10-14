"""Download the Kokoro model weights that the app bundles.

The ONNX file (156 MB) exceeds GitHub's file size limit, so it is published
as a release asset. The expected size and SHA-256 come from
assets/model/manifest.json; a mismatch leaves no file behind.

Usage: python3 tool/fetch_model.py
"""
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

RELEASES = 'https://github.com/Amoba-Software/lector-amoba/releases/download'

model_dir = Path(__file__).resolve().parent.parent / 'assets' / 'model'
manifest = json.loads((model_dir / 'manifest.json').read_text())
entry = next(item for item in manifest['files'] if item['path'] == 'model.onnx')
target = model_dir / 'model.onnx'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


if target.exists() and target.stat().st_size == entry['bytes'] and digest(target) == entry['sha256']:
    print(f'{target} is already present and verified.')
    sys.exit(0)

url = f"{RELEASES}/{manifest['version']}/model.onnx"
temporary = target.with_suffix('.onnx.part')
print(f'Downloading {url}')
with urllib.request.urlopen(url) as response, temporary.open('wb') as output:
    while block := response.read(1 << 20):
        output.write(block)
if temporary.stat().st_size != entry['bytes'] or digest(temporary) != entry['sha256']:
    temporary.unlink()
    sys.exit('Downloaded model does not match assets/model/manifest.json.')
temporary.replace(target)
print(f'Saved and verified {target}')
