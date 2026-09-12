"""Build OFL UI font subsets. Run with fonttools installed (see beta README).

Inputs are the three upstream Noto CJK SC OTF files in .tools/font-sources.
No fonts from the user's simulator or Windows installation are redistributed.
"""
from pathlib import Path
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tools/python'))
from fontTools import subset
from fontTools.ttLib import TTFont


def main():
    text = (ROOT / 'StarLux_LMM_v1.1.8.lua').read_text(encoding='utf-8-sig')
    # All source glyphs, ASCII, common punctuation; full simulator CJK fallback
    # is added at runtime for identifiers/text outside this UI subset.
    unicodes = sorted(set(map(ord, text)) | set(range(32, 127)) | {0x2026, 0xFFFD})
    out = ROOT / 'LMM_UI_118/fonts'
    out.mkdir(parents=True, exist_ok=True)
    manifest = {'upstream': 'https://github.com/notofonts/noto-cjk/tree/main/Sans',
                'license': 'SIL Open Font License 1.1', 'fonts': []}
    for weight in ('Regular', 'Medium', 'Bold'):
        source = ROOT / f'.tools/font-sources/NotoSansCJKsc-{weight}.otf'
        font = TTFont(source)
        options = subset.Options()
        options.name_IDs = ['*']
        options.name_languages = ['*']
        worker = subset.Subsetter(options=options)
        worker.populate(unicodes=unicodes)
        worker.subset(font)
        # Rename derivative to avoid representing a UI subset as the full font.
        names = {1: 'LMM UI', 2: weight, 3: f'LMM UI {weight} 1.1.8beta',
                 4: f'LMM UI {weight}', 6: f'LMMUI-{weight}', 16: 'LMM UI', 17: weight}
        for record in font['name'].names:
            if record.nameID in names:
                record.string = names[record.nameID].encode(record.getEncoding())
        cff = font['CFF '].cff
        cff.fontNames = [f'LMMUI-{weight}']
        cff.topDictIndex[0].FamilyName = 'LMM UI'
        cff.topDictIndex[0].FullName = f'LMM UI {weight}'
        target = out / f'LMMUI-{weight}.otf'
        font.save(target)
        manifest['fonts'].append({'file': target.name,
            'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
            'bytes': target.stat().st_size, 'glyphs': len(font.getBestCmap())})
        font.close()
    (out / 'OFL.txt').write_bytes((ROOT / '.tools/font-sources/OFL.txt').read_bytes())
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
