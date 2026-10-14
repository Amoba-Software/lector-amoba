"""Build a two-voice Kokoro candidate without modifying the input directory.

Requires onnx==1.19.1 and numpy==2.2.6. Half storage retains FP32 operators:
large FP32 initializers are rounded to FP16 and cast back before inference.
This reduces disk/download size; it does not promise lower inference RAM.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--model', type=Path)
    parser.add_argument('--precision', choices=['fp32', 'fp16-storage', 'int8'], required=True)
    parser.add_argument('--voices', default='ef_dora,em_alex',
                        help='Upstream voice names, in native order.')
    parser.add_argument('--tag', default='es-2voices')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output must be a new directory; existing resources are never overwritten.')
    source_model = args.model or args.source / 'model.onnx'
    model = onnx.load(source_model)
    original_graph = model.graph.SerializeToString()
    metadata = {item.key: item.value for item in model.metadata_props}
    names = metadata['speaker_names'].split(',')
    selected = args.voices.split(',')
    style_shape = tuple(map(int, metadata['style_dim'].split(',')))
    assert style_shape == (510, 1, 256), style_shape
    stride = np.prod(style_shape).item() * 4
    voices = (args.source / 'voices.bin').read_bytes()
    assert len(voices) == int(metadata['n_speakers']) * stride
    voice_data = b''.join(voices[names.index(name) * stride:(names.index(name) + 1) * stride] for name in selected)
    casts = []
    packed = 0
    if args.precision == 'fp16-storage':
        occupied = {name for node in model.graph.node for name in node.input} | {name for node in model.graph.node for name in node.output}
        occupied.update(t.name for t in model.graph.initializer)
        for tensor in model.graph.initializer:
            if tensor.data_type != TensorProto.FLOAT:
                continue
            values = numpy_helper.to_array(tensor)
            if values.size < 1024 or not np.isfinite(values).all() or np.abs(values).max() > 65504:
                continue
            original = tensor.name
            stored = original + '__amoba_fp16'
            assert stored not in occupied
            occupied.add(stored)
            tensor.CopyFrom(numpy_helper.from_array(values.astype(np.float16), stored))
            casts.append(helper.make_node('Cast', [stored], [original], name=stored + '_cast', to=TensorProto.FLOAT))
            packed += values.nbytes
        existing = list(model.graph.node)
        del model.graph.node[:]
        model.graph.node.extend(casts + existing)
    metadata.update({
        'n_speakers': str(len(selected)), 'speaker_names': ','.join(selected),
        'id2speaker': ','.join(f'{i}->{name}' for i, name in enumerate(selected)),
        'speaker2id': ','.join(f'{name}->{i}' for i, name in enumerate(selected)),
        'amoba_storage': args.precision,
    })
    helper.set_model_props(model, metadata)
    checker_note = None
    try:
        onnx.checker.check_model(model)
    except onnx.checker.ValidationError as error:
        # The upstream INT8 export has out-of-order lexical captures in Loop.
        # Accept only an unchanged graph; actual runtime loading is checked by
        # benchmark.dart before this candidate can be selected for the app.
        if args.precision != 'int8' or model.graph.SerializeToString() != original_graph:
            raise
        checker_note = str(error)
    shutil.copytree(args.source, args.output)
    onnx.save(model, args.output / 'model.onnx')
    (args.output / 'voices.bin').write_bytes(voice_data)
    version = f'kokoro-v1_0-{args.precision}-{args.tag}-1'
    profile = {
        'version': version, 'precision': args.precision,
        'sourceModelSha256': sha(source_model),
        'voices': {str(names.index(name)): i for i, name in enumerate(selected)},
        'packedInitializerBytesBefore': packed,
        'storageNote': 'FP16 weights, FP32 computation' if casts else args.precision,
        'upstreamCheckerNote': checker_note,
    }
    (args.output / 'profile.json').write_text(json.dumps(profile, indent=2) + '\n')
    files = [{'path': str(p.relative_to(args.output)), 'bytes': p.stat().st_size, 'sha256': sha(p)}
             for p in sorted(args.output.rglob('*')) if p.is_file() and p.name != 'manifest.json']
    upstream_source = json.loads((args.source / 'manifest.json').read_text())['source']
    manifest = {'version': version, 'source': str(source_model) if args.model else upstream_source,
                'transformation': profile, 'files': files}
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({**profile, 'modelBytes': (args.output / 'model.onnx').stat().st_size,
                      'voicesBytes': len(voice_data)}, indent=2))


if __name__ == '__main__':
    main()
