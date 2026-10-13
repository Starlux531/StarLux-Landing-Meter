"""Build the paired Markdown technical manuals as searchable, bookmarked PDFs.

Requires reportlab. Font arguments accept embeddable TrueType outlines, including
TTC collections. Windows Microsoft YaHei defaults cover both editions; font files
are not distributed by this script. Other platforms should supply licensed fonts.
"""
from __future__ import annotations

import argparse
import html
import re
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate, Frame, PageTemplate, Paragraph, Spacer, PageBreak,
    Table, TableStyle, CondPageBreak,
)
from reportlab.platypus.tableofcontents import TableOfContents

ROOT = Path(__file__).resolve().parents[1]
NAVY = colors.HexColor('#132D40')
TEAL = colors.HexColor('#007F88')
INK = colors.HexColor('#203443')
MUTED = colors.HexColor('#586B77')
RULE = colors.HexColor('#D6E2E7')


def inline(text: str) -> str:
    """Only the safe inline Markdown subset used by these source documents."""
    tokens: list[str] = []

    def token(value: str) -> str:
        tokens.append(value)
        return f'ZZTOKEN{len(tokens) - 1}ZZ'

    text = re.sub(r'\[([^\]]+)\]\((https://[^)]+)\)',
                  lambda m: token(f'<link href="{html.escape(m[2], quote=True)}" color="#007F88">'
                                  f'{html.escape(m[1])}</link>'), text)
    text = re.sub(r'`([^`]+)`', lambda m: token(
        f'<font color="#235D70">{html.escape(m[1])}</font>'), text)
    text = html.escape(text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', text)
    for index, value in enumerate(tokens):
        text = text.replace(f'ZZTOKEN{index}ZZ', value)
    return text


class ManualDoc(BaseDocTemplate):
    def __init__(self, filename: str, lang: str, **kw):
        super().__init__(filename, pagesize=A4, leftMargin=46, rightMargin=46,
                         topMargin=51, bottomMargin=47, **kw)
        self.lang = lang
        frame = Frame(self.leftMargin, self.bottomMargin, self.width, self.height,
                      leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
        self.addPageTemplates(PageTemplate(id='manual', frames=[frame], onPage=self.decorate))
        self.heading_counter = 0

    def beforeDocument(self):
        self.heading_counter = 0

    def decorate(self, canvas, doc):
        canvas.saveState()
        w, h = A4
        if doc.page == 1:
            canvas.setFillColor(NAVY)
            canvas.rect(0, h - 17, w, 17, fill=1, stroke=0)
        else:
            canvas.setFillColor(MUTED)
            canvas.setFont('Manual', 8)
            canvas.drawString(46, h - 30, 'STARLUX LMM / TECHNICAL MANUAL')
            canvas.setStrokeColor(RULE)
            canvas.line(46, h - 38, w - 46, h - 38)
        canvas.setStrokeColor(RULE)
        canvas.line(46, 36, w - 46, 36)
        canvas.setFont('Manual', 8)
        canvas.setFillColor(MUTED)
        canvas.drawString(46, 23, 'Manual 1.0 Final  |  Plugin 1.1.8  |  ' + self.lang)
        canvas.drawRightString(w - 46, 23, str(doc.page))
        canvas.restoreState()

    def afterFlowable(self, flowable):
        if isinstance(flowable, Paragraph) and flowable.style.name == 'Chapter':
            label = flowable.getPlainText()
            key = f'chapter-{self.heading_counter}'
            self.heading_counter += 1
            self.canv.bookmarkPage(key)
            self.canv.addOutlineEntry(label, key, level=0)
            self.notify('TOCEntry', (0, label, self.page, key))


def build(source: Path, output: Path, lang: str):
    cn = lang == 'CN'
    size, leading = (10.3, 17) if cn else (10, 15.4)
    body = ParagraphStyle('Body', fontName='Manual', fontSize=size, leading=leading,
                          textColor=INK, spaceAfter=8, splitLongWords=True,
                          wordWrap='CJK' if cn else None, rightIndent=11 if cn else 0,
                          allowWidows=0, allowOrphans=0)
    small = ParagraphStyle('Small', parent=body, fontSize=8.5, leading=12.5,
                           textColor=MUTED, spaceAfter=8)
    chapter = ParagraphStyle('Chapter', parent=body, fontName='ManualBold',
                             fontSize=17, leading=24, textColor=NAVY,
                             spaceBefore=17, spaceAfter=12, keepWithNext=True)
    sub = ParagraphStyle('Sub', parent=body, fontName='ManualBold', fontSize=11.5,
                         leading=17, textColor=TEAL, spaceBefore=11, spaceAfter=6,
                         keepWithNext=True)
    cell = ParagraphStyle('Cell', parent=body, fontSize=8.4, leading=12.5,
                          spaceAfter=0, allowWidows=1, allowOrphans=1)
    head_cell = ParagraphStyle('HeadCell', parent=cell, fontName='ManualBold', textColor=colors.white)
    title_style = ParagraphStyle('CoverTitle', parent=body, fontName='ManualBold',
                                 fontSize=32, leading=44, textColor=NAVY, spaceAfter=22)
    subtitle = ParagraphStyle('Subtitle', parent=body, fontSize=14, leading=23,
                              textColor=TEAL, spaceAfter=25)
    lines = source.read_text(encoding='utf-8').splitlines()
    assert len([line for line in lines if line.startswith('## ')]) == 15
    first_section = next(i for i, line in enumerate(lines) if line.startswith('## '))
    front = '\n'.join(lines[1:first_section]).strip().split('\n\n')
    story = [Spacer(1, 48), Paragraph('IMPLEMENTATION REFERENCE', small), Spacer(1, 20),
             Paragraph(inline(lines[0][2:]), title_style), Paragraph(inline(front[0]), subtitle)]
    for p in front[1:]:
        story.append(Paragraph(inline(p.replace('\n', ' ')), body))
    story.extend([Spacer(1, 32), Paragraph('DATA SOURCES  /  ALGORITHMS  /  REVIEW LIMITS', small),
                  PageBreak(), Paragraph('目录' if cn else 'Contents', title_style)])
    toc = TableOfContents()
    toc.levelStyles = [ParagraphStyle('Toc', parent=body, fontSize=10, leading=19,
                                     leftIndent=0, firstLineIndent=0, spaceBefore=3)]
    story.extend([toc, Spacer(1, 20), Paragraph(
        '章节在 PDF 中提供书签，正文来源链接可点击。' if cn else
        'PDF bookmarks and source links are clickable.', small), PageBreak()])

    i = first_section
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        if line.startswith('## '):
            story.extend([CondPageBreak(155), Paragraph(inline(line[3:]), chapter)])
            i += 1
        elif line.startswith('### '):
            story.append(Paragraph(inline(line[4:]), sub))
            i += 1
        elif line.startswith('|'):
            rows = []
            while i < len(lines) and lines[i].strip().startswith('|'):
                cells = [s.strip() for s in lines[i].strip().strip('|').split('|')]
                if not all(re.fullmatch(r':?-+:?', s) for s in cells):
                    rows.append(cells)
                i += 1
            columns = len(rows[0])
            if any(len(row) != columns for row in rows):
                raise ValueError(f'Misaligned Markdown table near source line {i}')
            fractions = {2: [0.31, 0.69], 3: [0.23, 0.43, 0.34],
                         4: [0.10, 0.30, 0.36, 0.24]}[columns]
            data = [[Paragraph(inline(value), head_cell if j == 0 else cell)
                     for value in row] for j, row in enumerate(rows)]
            table = Table(data, colWidths=[(A4[0]-92)*f for f in fractions],
                          repeatRows=1, hAlign='LEFT')
            table.setStyle(TableStyle([
                ('BACKGROUND', (0,0), (-1,0), NAVY),
                ('ROWBACKGROUNDS', (0,1), (-1,-1), [colors.HexColor('#F0F5F7'), colors.white]),
                ('VALIGN', (0,0), (-1,-1), 'TOP'),
                ('LEFTPADDING', (0,0), (-1,-1), 8),
                ('RIGHTPADDING', (0,0), (-1,-1), 8),
                ('TOPPADDING', (0,0), (-1,-1), 7),
                ('BOTTOMPADDING', (0,0), (-1,-1), 7),
                ('LINEBELOW', (0,0), (-1,0), .6, NAVY),
                ('LINEBELOW', (0,1), (-1,-1), .3, RULE),
            ]))
            story.extend([table, Spacer(1, 11)])
        else:
            paragraph = [line]
            numbered = re.match(r'^\d+\. ', line)
            i += 1
            if not numbered:
                while i < len(lines) and lines[i].strip() and not lines[i].startswith(('#', '|')):
                    paragraph.append(lines[i].strip())
                    i += 1
            text = ' '.join(paragraph)
            style = small if text.startswith(('来源：', 'Source:', 'Sources:')) else body
            story.append(Paragraph(inline(text), style))
    output.parent.mkdir(parents=True, exist_ok=True)
    doc = ManualDoc(str(output), lang, title=f'StarLux LMM Technical Manual 1.0 / {lang}',
                    author='StarLux LMM', subject='Plugin 1.1.8 implementation reference')
    doc.multiBuild(story)
    print(f'{output.name}: {doc.page} pages; {output.stat().st_size:,} bytes')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--font', type=Path, default=Path('C:/Windows/Fonts/msyh.ttc'))
    parser.add_argument('--bold-font', type=Path, default=Path('C:/Windows/Fonts/msyhbd.ttc'))
    parser.add_argument('--output', type=Path, default=ROOT/'output/pdf')
    args = parser.parse_args()
    for name, font in [('Manual', args.font), ('ManualBold', args.bold_font)]:
        pdfmetrics.registerFont(TTFont(name, str(font), subfontIndex=0))
    pdfmetrics.registerFontFamily('Manual', normal='Manual', bold='ManualBold',
                                italic='Manual', boldItalic='ManualBold')
    for lang in ['CN', 'EN']:
        stem = f'StarLux_LMM_Technical_Manual_1.0_{lang}'
        build(ROOT/'docs/technical-manual'/f'{stem}.md', args.output/f'{stem}.pdf', lang)


if __name__ == '__main__':
    main()
