"""Activate a verified candidate and generate its matching Dart voice profile."""
import hashlib
import json
import shutil
import sys
from pathlib import Path

candidate = Path(sys.argv[1])
target = Path('assets/model')
manifest = json.loads((candidate / 'manifest.json').read_text())
profile = json.loads((candidate / 'profile.json').read_text())
assert manifest['version'] == profile['version']
for item in manifest['files']:
    path = candidate / item['path']
    assert path.is_relative_to(candidate) and '..' not in Path(item['path']).parts
    assert path.stat().st_size == item['bytes'], path
    with path.open('rb') as stream:
        assert hashlib.file_digest(stream, 'sha256').hexdigest() == item['sha256'], path
    if item['path'] not in ['model.onnx', 'voices.bin', 'profile.json']:
        with (target / item['path']).open('rb') as stream:
            assert hashlib.file_digest(stream, 'sha256').hexdigest() == item['sha256'], path
mapping = {int(k): int(v) for k, v in profile['voices'].items()}
assert {28, 29} <= set(mapping) and sorted(mapping.values()) == list(range(len(mapping)))
backup = Path('.dart_tool/original-model')
if not backup.exists():
    backup.mkdir(parents=True)
    for name in ['model.onnx', 'voices.bin', 'manifest.json']:
        shutil.copy2(target / name, backup / name)
    shutil.copy2('lib/model_profile.dart', backup / 'model_profile.dart')
for name in ['model.onnx', 'voices.bin', 'profile.json', 'manifest.json']:
    temporary = target / (name + '.tmp')
    shutil.copyfile(candidate / name, temporary)
    temporary.replace(target / name)
Path('lib/model_profile.dart').write_text(
    "// Updated by tool/select_model.py together with the model manifest.\n"
    f"const modelVersion = '{profile['version']}';\n"
    f"const nativeVoiceIds = {mapping};\n"
    f"const expectedNativeSpeakers = {len(mapping)};\n"
)
print(f"Activated {profile['version']}; original model saved in {backup}")
