"""Write work/patched/main.changed.tsv: the main text words a cheat must not overwrite.

The cheat engine (host/cheats.c, from nxnative) refuses a code write into a word the rewriter changed or moved, so a
cheat's instruction (or an on / off pair's restore of the Switch's original word) cannot undo a rewritten site. The
words are every text word whose bytes differ between the original NSO and main.patched.bin (rewritten sites, the
frame-step and render-scale patches) plus every word main.sites.tsv lists (window words whose copies run instead).
Output, as nxnative's patch_nso.py writes it: a "# BUILD_ID" header, then sorted, merged "offset<TAB>length" runs in hex.
"""
from pathlib import Path
import struct
import sys

import lz4.block

ROOT = Path(__file__).resolve().parents[1]


def original_image(nso):
    data = nso.read_bytes()
    if data[:4] != b'NSO0':
        raise ValueError(f'{nso}: not an NSO')
    flags = struct.unpack_from('<I', data, 0xc)[0]
    segments = [struct.unpack_from('<III', data, 0x10 + i * 0x10) for i in range(3)]
    sizes = struct.unpack_from('<III', data, 0x60)
    image = bytearray(segments[2][1] + segments[2][2])
    for i, (file_offset, memory_offset, size) in enumerate(segments):
        raw = data[file_offset:file_offset + sizes[i]]
        if flags >> i & 1:
            raw = lz4.block.decompress(raw, uncompressed_size=size)
        image[memory_offset:memory_offset + size] = raw
    return image, segments[0][2], data[0x40:0x50].hex()


def changed_runs(original, patched, text_end, sites):
    words = {offset for offset in range(0, text_end, 4) if original[offset:offset + 4] != patched[offset:offset + 4]}
    words |= {offset & ~3 for offset in sites if offset < text_end}
    runs = []
    for offset in sorted(words):
        if runs and runs[-1][0] + runs[-1][1] == offset:
            runs[-1][1] += 4
        else:
            runs.append([offset, 4])
    return runs


def main():
    patched_dir = ROOT / 'work/patched'
    output = patched_dir / 'main.changed.tsv'
    original, text_end, build_id = original_image(ROOT / 'work/exefs/main')
    patched = (patched_dir / 'main.patched.bin').read_bytes()
    if len(patched) < text_end:
        raise ValueError('main.patched.bin is shorter than the text')
    sites = [int(line.split('\t', 1)[0], 16) for line in (patched_dir / 'main.sites.tsv').read_text().splitlines()
             if line and not line.startswith('#')]
    runs = changed_runs(original, patched, text_end, sites)
    text = f'# BUILD_ID\t{build_id}\n' + ''.join(f'{offset:#x}\t{length:#x}\n' for offset, length in runs)
    if output.exists() and output.read_text() == text:
        return
    temporary = output.with_suffix('.tmp')
    temporary.write_text(text)
    temporary.replace(output)
    print(f'Cheat guard: {len(runs)} runs of changed text words ({sum(n for _, n in runs) // 4} words) in {output}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        sys.exit(str(error))
