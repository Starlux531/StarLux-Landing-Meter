"""Documentation checks only; not a substitute for simulator validation."""
from pathlib import Path
import re
import unittest
from decimal import Decimal, ROUND_HALF_UP

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / 'docs/technical-manual'
BASELINE = '6a1c62ab433a764afecb14e98fb7f1b4b91f548e'


class TechnicalManualTests(unittest.TestCase):
    def setUp(self):
        self.lua = (ROOT/'StarLux_LMM_v1.1.8.lua').read_text(encoding='utf-8')
        self.editions = [(DOCS/f'StarLux_LMM_Technical_Manual_1.0_{lang}.md')
                         .read_text(encoding='utf-8') for lang in ['CN', 'EN']]

    def test_paired_structure_sources_and_interfaces(self):
        for text in self.editions:
            self.assertEqual(re.findall(r'^## (\d{2}) ', text, re.M),
                             [f'{n:02}' for n in range(1, 16)])
            urls = re.findall(r'\]\((https://[^)]+)\)', text)
            self.assertGreater(len(urls), 20)
            self.assertTrue(all(BASELINE in url for url in urls))
            for token in re.findall(r'`([^`]+)`', text):
                if re.match(r'^(sim/|AirbusFBW/|laminar/|Rotate/|A300/|1-sim/)', token):
                    self.assertIn(token, self.lua, token)

    def test_critical_documented_parameters_remain_in_source(self):
        for statement in ['write_chunk_bytes = 8192', 'min_pair_gap_seconds = 0.035',
                          'centerline_downgrade_m = 7.0', 'centerline_unstable_m = 15.0']:
            self.assertIn(statement, self.lua)
        for text in self.editions:
            for value in ['0.035', '0.050', '0.075', '8192', '0.00508', '9.80665',
                          '0.006', '0.62', '0.75', '0.160', '720', '256']:
                self.assertIn(value, text)

    def test_synthetic_examples(self):
        # Independent arithmetic checks of the manual's examples, not a re-test
        # of simulator acquisition or an execution of the complete Lua script.
        d = Decimal
        self.assertEqual(abs(d('-104')-d('-63')), 41)
        self.assertEqual(abs(d('-65')-d('-63')), 2)
        values = [d(s) for s in ['1.00', '1.08', '1.12', '1.20', '1.34']]
        index = int((len(values)*d('.75')).to_integral_value(rounding='ROUND_CEILING'))
        self.assertEqual(values[index-1], d('1.20'))
        self.assertEqual(abs(d('.2')-d('.5'))/d('.5'), d('.6'))
        self.assertEqual(d('-100.5').quantize(d('1'), rounding=ROUND_HALF_UP), -101)

    def test_pdf_headers_and_local_document_links(self):
        for lang in ['CN', 'EN']:
            pdf = DOCS/f'StarLux_LMM_Technical_Manual_1.0_{lang}.pdf'
            self.assertTrue(pdf.read_bytes().startswith(b'%PDF-'))
        for path in [ROOT/'README.md', ROOT/'README_1.1.8.md', DOCS/'README.md']:
            for ref in re.findall(r'\]\(([^)]+)\)', path.read_text(encoding='utf-8')):
                if not re.match(r'^(https?://|#)', ref):
                    self.assertTrue((path.parent/ref.split('#')[0]).exists(), (path.name, ref))


if __name__ == '__main__':
    unittest.main()
