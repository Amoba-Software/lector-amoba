"""Verify the packaged model, licenses and ARM64 libraries against the workspace."""
import hashlib
import json
import sys
import zipfile
from pathlib import Path
from urllib.parse import quote

apk = Path(sys.argv[1])
manifest_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path('assets/model/manifest.json')
manifest = json.loads(manifest_path.read_text())

def digest(stream):
    result = hashlib.sha256()
    for block in iter(lambda: stream.read(65536), b''):
        result.update(block)
    return result.hexdigest()

with zipfile.ZipFile(apk) as archive:
    abis = sorted({name.split('/')[1] for name in archive.namelist() if name.startswith('lib/')})
    assert abis == ['arm64-v8a'], abis
    root = 'assets/flutter_assets/assets/model/'
    assert json.loads(archive.read(root + 'manifest.json')) == manifest
    for entry in manifest['files']:
        # Flutter packages asset paths as URI paths, including percent-encoded spaces.
        name = quote(root + entry['path'], safe="/!$&'()*+,-.:;=@_~")
        assert archive.getinfo(name).file_size == entry['bytes'], name
        with archive.open(name) as stream:
            assert digest(stream) == entry['sha256'], name
    for name in ['espeak-ng-COPYING', 'kokoro-LICENSE', 'sherpa-onnx-LICENSE']:
        assert 'assets/flutter_assets/assets/licenses/' + name in archive.namelist()
with apk.open('rb') as stream:
    sha = digest(stream)
report = {'apk': apk.name, 'bytes': apk.stat().st_size, 'sha256': sha,
          'abis': abis, 'modelFilesVerified': len(manifest['files']),
          'modelVersion': manifest['version'],
          'resourcesBytes': sum(entry['bytes'] for entry in manifest['files'])}
(apk.parent / (apk.stem + '.json')).write_text(json.dumps(report, indent=2) + '\n')
checksums = apk.parent / 'SHA256SUMS'
existing = checksums.read_text().splitlines() if checksums.exists() else []
existing = [line for line in existing if not line.endswith('  ' + apk.name)]
checksums.write_text('\n'.join(existing + [sha + '  ' + apk.name]) + '\n')
print(json.dumps(report, indent=2))
