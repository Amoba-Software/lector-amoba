"""Build a separate Piper app, restoring the Kokoro resources even on failure.

Usage: python3 tool/build_piper_trial.py PIPER_INT8_DIRECTORY
The default Flutter build remains Kokoro. Piper needs both a Dart define and
the matching Gradle property; this script sets both and verifies its artifact.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1]).resolve()
assert (source / 'es_MX-ald-medium.onnx').is_file()
assert (source / 'MODEL_CARD').is_file()
target = Path('assets/model')
temporary = Path(tempfile.mkdtemp(prefix='piper-build-', dir='.dart_tool'))
backup = temporary / 'kokoro-model'
destination = Path('deliverables/lector-amoba-piper-arm64.apk')
version = 'piper-es_MX-ald-medium-int8-1'
profile = {'version': version, 'engine': 'piper', 'precision': 'int8', 'voices': {'28': 0},
           'sampleRate': 22050, 'speakers': 1,
           'source': 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_MX-ald-medium-int8.tar.bz2'}
swapped = False
try:
    target.rename(backup)
    swapped = True
    shutil.copytree(source, target)
    (target / 'es_MX-ald-medium.onnx').rename(target / 'model.onnx')
    (target / 'profile.json').write_text(json.dumps(profile, indent=2) + '\n')
    files = []
    for path in sorted(target.rglob('*')):
        if path.is_file() and path.name != 'manifest.json':
            with path.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            files.append({'path': str(path.relative_to(target)), 'bytes': path.stat().st_size, 'sha256': digest})
    manifest = {'version': version, 'source': profile['source'], 'files': files}
    (target / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    environment = os.environ.copy()
    environment['ORG_GRADLE_PROJECT_piperTrial'] = 'true'
    subprocess.run(['flutter', 'test', '--no-pub', '--dart-define=PIPER_TRIAL=true'], env=environment, check=True)
    subprocess.run(['flutter', 'analyze', '--no-pub'], env=environment, check=True)
    subprocess.run(['flutter', 'build', 'apk', '--release', '--no-pub', '--target-platform', 'android-arm64',
                    '--dart-define=PIPER_TRIAL=true'], env=environment, check=True)
    shutil.copyfile('build/app/outputs/flutter-apk/app-release.apk', destination)
    manifest_copy = destination.with_suffix('.manifest.json')
    shutil.copyfile(target / 'manifest.json', manifest_copy)
    subprocess.run([sys.executable, 'tool/verify_apk.py', str(destination), str(manifest_copy)], check=True)
    print(f'Piper trial ready: {destination}. Application ID: ec.amoba.lector_amoba.piper')
finally:
    if swapped:
        if target.exists():
            shutil.rmtree(target)
        backup.rename(target)
    shutil.rmtree(temporary)
