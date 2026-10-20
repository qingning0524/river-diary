from pathlib import Path
import hashlib
import html
import json
import re

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import BaseDocTemplate, Frame, PageTemplate, Paragraph, Spacer, PageBreak, Image, Table, TableStyle, Flowable
from reportlab.platypus.tableofcontents import TableOfContents

ROOT = Path('/Users/fa1lingdown/Desktop/河流日记项目')
REFS = Path('/Users/fa1lingdown/.gstack/projects/qingning0524-river-diary/designs/mobile-ten-20261002')
OUT = ROOT / 'output/pdf/RiverDiary_iOS_Theme_Design_2026-10-02.pdf'
OUT.parent.mkdir(parents=True, exist_ok=True)
SOURCE = ROOT / 'docs/IOS_THEME_SYSTEM_DESIGN_2026-10-02.md'
CATALOG = json.loads((ROOT / 'docs/IOS_THEME_CATALOG_V1.json').read_text())

pdfmetrics.registerFont(TTFont('RiverBody', '/System/Library/Fonts/Supplemental/Arial Unicode.ttf'))
pdfmetrics.registerFont(TTFont('RiverHeading', '/System/Library/Fonts/STHeiti Medium.ttc', subfontIndex=0))
pdfmetrics.registerFontFamily('RiverBody', normal='RiverBody', bold='RiverHeading', italic='RiverBody', boldItalic='RiverHeading')
PAGE_W, PAGE_H = A4
MARGIN = 42
WIDTH = PAGE_W - MARGIN * 2
INK = colors.HexColor('#29392B')
ACCENT = colors.HexColor('#41634A')
SUB = colors.HexColor('#64735E')
LINE = colors.HexColor('#D8DFD1')
PAPER = colors.HexColor('#F2F4EC')

styles = {
    'body': ParagraphStyle('Body', fontName='RiverBody', fontSize=10.2, leading=16, textColor=INK, wordWrap='CJK', spaceAfter=6),
    'h1': ParagraphStyle('Heading1', fontName='RiverHeading', fontSize=17, leading=24, textColor=ACCENT, spaceBefore=17, spaceAfter=9, keepWithNext=True, wordWrap='CJK'),
    'h2': ParagraphStyle('Heading2', fontName='RiverHeading', fontSize=12.3, leading=19, textColor=INK, spaceBefore=10, spaceAfter=5, keepWithNext=True, wordWrap='CJK'),
    'small': ParagraphStyle('Small', fontName='RiverBody', fontSize=9, leading=14, textColor=SUB, wordWrap='CJK', spaceAfter=5),
    'quote': ParagraphStyle('Quote', fontName='RiverBody', fontSize=10.8, leading=18, leftIndent=13, rightIndent=12, textColor=ACCENT, borderColor=LINE, borderWidth=.7, borderPadding=10, backColor=PAPER, spaceBefore=8, spaceAfter=13, wordWrap='CJK'),
    'bullet': ParagraphStyle('Bullet', fontName='RiverBody', fontSize=10.2, leading=16, leftIndent=13, firstLineIndent=0, bulletIndent=1, textColor=INK, spaceAfter=5, wordWrap='CJK'),
    'cell': ParagraphStyle('Cell', fontName='RiverBody', fontSize=8.7, leading=13.2, textColor=INK, wordWrap='CJK'),
    'cellhead': ParagraphStyle('CellHead', fontName='RiverHeading', fontSize=9, leading=13.5, textColor=ACCENT, wordWrap='CJK'),
    'cover': ParagraphStyle('CoverTitle', fontName='RiverHeading', fontSize=32, leading=42, textColor=INK, spaceAfter=20, wordWrap='CJK'),
    'coverintro': ParagraphStyle('CoverIntro', fontName='RiverBody', fontSize=12, leading=20, textColor=SUB, spaceAfter=16, wordWrap='CJK'),
    'front': ParagraphStyle('FrontTitle', fontName='RiverHeading', fontSize=22, leading=30, textColor=ACCENT, spaceAfter=13, keepWithNext=True),
    'appendix': ParagraphStyle('AppendixTitle', fontName='RiverHeading', fontSize=17, leading=24, textColor=ACCENT, spaceBefore=5, spaceAfter=7, keepWithNext=True),
}


def inline(text):
    text = html.escape(text)
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', lambda m: f'<link href="{m[2]}" color="#41634A">{m[1]}</link>' if m[2].startswith('http') else m[1], text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', text)
    text = re.sub(r'`([^`]+)`', lambda m: f'<font name="{"RiverBody" if any(ord(c)>127 for c in m[1]) else "Courier"}" size="9">{m[1]}</font>', text)
    return text


class ThemeFlow(Flowable):
    def __init__(self):
        super().__init__()
        self.width = WIDTH
        self.height = 128

    def draw(self):
        c = self.canv
        boxes = [('浏览', '十版都可使用', '当前主题有勾选'), ('预览', '看今天与详情', '关闭即回到原主题'), ('应用', '使用此主题', '提交本机偏好'), ('继续', '保留当前页面', '日期、草稿不丢失'), ('撤销', '五秒内可撤销', '回到上一次主题')]
        gap = 11
        w = (WIDTH - gap * 4) / 5
        for i, (title, a, b) in enumerate(boxes):
            x = i * (w + gap)
            c.setFillColor(PAPER)
            c.setStrokeColor(LINE)
            c.roundRect(x, 35, w, 82, 8, fill=1, stroke=1)
            c.setFillColor(ACCENT)
            c.setFont('RiverHeading', 13)
            c.drawCentredString(x + w / 2, 91, title)
            c.setFont('RiverBody', 8.6)
            c.setFillColor(SUB)
            c.drawCentredString(x + w / 2, 68, a)
            c.drawCentredString(x + w / 2, 53, b)
            if i < 4:
                c.setStrokeColor(ACCENT)
                c.line(x + w + 2, 76, x + w + gap - 2, 76)
                c.line(x + w + gap - 4, 79, x + w + gap - 1, 76)
                c.line(x + w + gap - 4, 73, x + w + gap - 1, 76)
        c.setFont('RiverBody', 9)
        c.setFillColor(SUB)
        c.drawString(0, 13, '预览与应用分开；主题切换只影响呈现，业务记录和分析按原有链路运行。')


class PaletteStrip(Flowable):
    def __init__(self, definition):
        super().__init__()
        self.definition = definition
        self.width = WIDTH
        self.height = 47

    def draw(self):
        c = self.canv
        roles = ['canvas', 'surface', 'ink', 'accent']
        for row, mode in enumerate(['light', 'dark']):
            y = 28 - row * 23
            c.setFillColor(SUB)
            c.setFont('RiverBody', 8.5)
            c.drawString(0, y + 3, '浅色' if mode == 'light' else '深色')
            for j, role in enumerate(roles):
                x = 38 + j * 112
                value = self.definition['palettes'][mode][role]
                c.setFillColor(colors.HexColor(value))
                c.setStrokeColor(LINE)
                c.roundRect(x, y, 17, 15, 3, fill=1, stroke=1)
                c.setFillColor(SUB)
                c.setFont('Courier', 8)
                c.drawString(x + 23, y + 4, value)


class ThemeDocument(BaseDocTemplate):
    def afterFlowable(self, flowable):
        if not isinstance(flowable, Paragraph):
            return
        if flowable.style.name not in ['Heading1', 'AppendixTitle']:
            return
        text = flowable.getPlainText()
        key = 'section-' + hashlib.md5(text.encode()).hexdigest()
        level = 1 if flowable.style.name == 'AppendixTitle' else 0
        self.canv.bookmarkPage(key)
        self.canv.addOutlineEntry(text, key, level=level, closed=False)
        self.notify('TOCEntry', (level, text, self.page, key))


def page_decoration(canvas, doc):
    canvas.saveState()
    if doc.page > 1:
        canvas.setStrokeColor(LINE)
        canvas.setLineWidth(.6)
        canvas.line(MARGIN, PAGE_H - 30, PAGE_W - MARGIN, PAGE_H - 30)
        canvas.setFillColor(SUB)
        canvas.setFont('RiverBody', 8)
        canvas.drawString(MARGIN, PAGE_H - 23, '河流日记 / iOS 十主题系统设计')
        canvas.setFont('Courier', 8)
        canvas.drawRightString(PAGE_W - MARGIN, PAGE_H - 23, 'V1.0  |  2026-10-02')
    canvas.setStrokeColor(LINE)
    canvas.line(MARGIN, 31, PAGE_W - MARGIN, 31)
    canvas.setFillColor(SUB)
    canvas.setFont('RiverBody', 8)
    canvas.drawString(MARGIN, 19, '十版方向已确认 · 第一版已实现 · 全量验收进行中 · 图稿数据为示例')
    canvas.setFont('Courier', 8)
    canvas.drawRightString(PAGE_W - MARGIN, 19, f'{doc.page:02d}')
    canvas.restoreState()


def make_table(lines):
    rows = [[x.strip() for x in line.strip().strip('|').split('|')] for line in lines]
    rows = [r for r in rows if not all(re.fullmatch(r'[:\-\s]+', x or '-') for x in r)]
    count = len(rows[0])
    proportions = {2: [1.1, 3.1], 3: [1.0, 1.45, 2.75], 4: [1.7, 1.0, 2.0, .75]}
    weights = proportions.get(count, [1] * count)
    widths = [WIDTH * w / sum(weights) for w in weights]
    cellrows = [[Paragraph(inline(cell), styles['cellhead' if i == 0 else 'cell']) for cell in row] for i, row in enumerate(rows)]
    table = Table(cellrows, colWidths=widths, repeatRows=1, hAlign='LEFT')
    table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, 0), PAPER),
        ('VALIGN', (0, 0), (-1, -1), 'TOP'),
        ('LINEBELOW', (0, 0), (-1, 0), .8, colors.HexColor('#ADBCA3')),
        ('LINEBELOW', (0, 1), (-1, -1), .4, LINE),
        ('TOPPADDING', (0, 0), (-1, -1), 7),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 7),
        ('LEFTPADDING', (0, 0), (-1, -1), 8),
        ('RIGHTPADDING', (0, 0), (-1, -1), 8),
    ]))
    return table


def markdown_flow(text):
    lines = text.splitlines()
    result, i = [], 0
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        if line.startswith('## '):
            result.append(Paragraph(inline(line[3:]), styles['h1']))
            if line.startswith('## 5.'):
                result.append(ThemeFlow())
            i += 1
        elif line.startswith('### '):
            result.append(Paragraph(inline(line[4:]), styles['h2']))
            i += 1
        elif line.startswith('|'):
            rows = []
            while i < len(lines) and lines[i].strip().startswith('|'):
                rows.append(lines[i])
                i += 1
            result.extend([make_table(rows), Spacer(1, 8)])
        elif line.startswith('- '):
            result.append(Paragraph(inline(line[2:]), styles['bullet'], bulletText='•'))
            i += 1
        elif re.match(r'^\d+\. ', line):
            number, body = line.split('. ', 1)
            result.append(Paragraph(inline(body), styles['bullet'], bulletText=number + '.'))
            i += 1
        elif line.startswith('> '):
            result.append(Paragraph(inline(line[2:]), styles['quote']))
            i += 1
        else:
            parts = [line]
            i += 1
            while i < len(lines) and lines[i].strip() and not re.match(r'^(#{2,3} |\||- |\d+\. |> )', lines[i].strip()):
                parts.append(lines[i].strip())
                i += 1
            result.append(Paragraph(inline(' '.join(parts)), styles['body']))
    return result


source = SOURCE.read_text()
body = source[source.index('## 1.'):]
story = [Spacer(1, 15), Paragraph('RIVER DIARY / MOBILE DESIGN', styles['small']), Spacer(1, 10), Paragraph('十种界面，<br/>一份完整的生活。', styles['cover']), Paragraph('河流日记 iOS 十主题系统设计文稿', styles['coverintro'])]
story.append(Paragraph('十个视觉方向全部保留，转化为可自由切换的主题。<br/>本册定义产品结构、视觉差异、切换流程、实施架构与验收，<br/>并完整收录十版双屏参考图。', styles['coverintro']))
overview = Image(str(REFS / 'overview.png'), width=WIDTH, height=WIDTH * 1200 / 1800)
overview.hAlign = 'CENTER'
story.extend([overview, Spacer(1, 14), Paragraph('V1.0 · 2026-10-02 · 用户已确认十个方向全部作为主题', styles['small']), Paragraph('十主题第一版已在 iOS 实现；完整页面矩阵、无障碍和性能验收仍待完成。', styles['small']), PageBreak()])
story.extend([Paragraph('阅读目录', styles['front']), Paragraph('先看产品结构与十款契约，再看切换与实现状态。附录中的双屏图保持原稿，浅深色变量是运行时首版的基础定义。', styles['body']), Spacer(1, 10)])
toc = TableOfContents()
toc.tableStyle = TableStyle([('VALIGN', (0, 0), (-1, -1), 'TOP'), ('LEFTPADDING', (0, 0), (-1, -1), 0), ('RIGHTPADDING', (0, 0), (-1, -1), 0), ('TOPPADDING', (0, 0), (-1, -1), 0), ('BOTTOMPADDING', (0, 0), (-1, -1), 0)])
toc.levelStyles = [ParagraphStyle('TOC0', fontName='RiverBody', fontSize=10.5, leading=17.5, textColor=INK, leftIndent=0, firstLineIndent=0, spaceBefore=1, spaceAfter=0, wordWrap='CJK'), ParagraphStyle('TOC1', fontName='RiverBody', fontSize=9.2, leading=15, textColor=SUB, leftIndent=14, firstLineIndent=0, spaceBefore=0, spaceAfter=0, wordWrap='CJK')]
story.extend([toc, PageBreak()])
story.extend(markdown_flow(body))
story.extend([PageBreak(), Paragraph('视觉附录 · 十个主题', styles['h1']), Paragraph('原稿每版两屏。参考图中的生活数据为示例；浅深色变量须继续扩展到正式组件与完整页面。', styles['small'])])
descriptions = [
    '纸张、衬线与章节时间。今天像手记，片段像值得重读的一页。',
    '地图、真实地点与下方生活故事。相同日期与活动沿着位置展开。',
    '琥珀胶片与影像叙事。照片是主视觉，生活记录与温和理解共同组成画面。',
    '连续生活流与珊瑚色重点。用清楚的时间、标题和操作快速扫读今天。',
    '活动与记忆的实际关联。星图保留列表入口，字体和辅助设置优先。',
    '青瓷、陶土与静态自然插画。轻松记录日常，不把生活变成分数或任务。',
    '大日期、分栏与私人刊物。重点片段成为日头条，每周回顾成为一份私刊。',
    '真实时间范围形成一天的节奏。未知时段留白，日汇总不伪装成零点活动。',
    '纸张、照片与用户短句。轻微错位保留收藏感，长文字与辅助字号恢复清楚单栏。',
    '清楚的片段与上下文理解。留住真正发生的事，补充与更正始终可达。',
]
for index, theme in enumerate(CATALOG['themes']):
    if index:
        story.append(PageBreak())
    title = f'{index + 1:02d}  {theme["name"]}'
    story.append(Paragraph(title, styles['appendix']))
    story.append(Paragraph(f'<font name="Courier">{theme["id"]}</font> / 参考外观：{"深色" if theme["referenceAppearance"] == "dark" else "浅色"}', styles['small']))
    story.append(Paragraph(descriptions[index], styles['small']))
    image_width = WIDTH - (44 if index == 0 else 24)
    image = Image(str(REFS / theme['referencePng']), width=image_width, height=image_width * 1160 / 1080)
    image.hAlign = 'CENTER'
    story.extend([image, Spacer(1, 9), PaletteStrip(theme), Paragraph('色条依次为画布、表面、正文与交互色；是设计定义，正式界面仍须按状态验收。', styles['small'])])

doc = ThemeDocument(str(OUT), pagesize=A4, leftMargin=MARGIN, rightMargin=MARGIN, topMargin=46, bottomMargin=45, title='河流日记 iOS 十主题系统设计文稿 V1.0', author='River Diary', subject='Ten theme product design, switching, architecture and visual references')
frame = Frame(MARGIN, 45, WIDTH, PAGE_H - 91, leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
doc.addPageTemplates([PageTemplate(id='body', frames=[frame], onPage=page_decoration)])
doc.multiBuild(story)
print(str(OUT))
