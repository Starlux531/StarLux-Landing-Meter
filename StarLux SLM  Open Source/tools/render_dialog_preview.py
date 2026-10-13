"""Render actual dialog draw commands with real font metrics, without X-Plane.

This is an offline UI preview, not an SDK/Vulkan screenshot or simulated flight.
Uses the existing recorder SDK double; never loads the real XPLM DLL.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
sys.path.insert(0, str(ROOT / '.tools/python'))
from test_ui_118 import RecorderTests
from PIL import Image, ImageDraw, ImageFont


def render(page, language='zh', width=860, height=850):
    lua = RecorderTests().load_recorder()
    fonts = {i: ImageFont.truetype(str(ROOT / 'LMM_UI_118/fonts' / f'LMMUI-{w}.otf'), 15)
             for i, w in enumerate(('Regular', 'Medium', 'Bold'), 1)}
    lua.globals().font_width = lambda i, px, s: fonts[int(i)].getlength(s)
    lua.execute('''
        api.XPLMFontMeasureString=function(font,px,text)
            return font_width(tonumber(ffi.cast('intptr_t',font)),px,text)
        end
        ma_open_settings_window(); host=ui.native_ui.instance
    ''')
    lua.globals().language = language
    lua.globals().page_name = page
    lua.globals().view_width, lua.globals().view_height = width, height
    lua.execute('''
        ui.set_global_language(language)
        if page_name=='records' then
            local state=getup(ma_build_log_manager_window,'log_manager_state')
            state.records={}; state.scan_error=''
            for i=1,126 do state.records[i]={name='LMM_fixture_'..i..'.txt',display_name='2026-09-12 13:43:21  |  ZGNN A20N RWY05'} end
            ma_open_log_manager(); d=host.dialogs.records
        else
            ui.settings_ui_tab=page_name; d=host.dialogs.settings
        end
        api.XPLMSetWindowGeometry(d.window,0,view_height,view_width,0)
        d.scroll=0; d:tick(); d:tick()
    ''')
    im = Image.new('RGB', (width, height), '#101923')
    draw = ImageDraw.Draw(im)

    def color(v):
        n = int(v)
        return n & 255, (n >> 8) & 255, (n >> 16) & 255

    def rect(x, y, w, h, c):
        if w > 0 and h > 0:
            draw.rectangle((x, height-y-h, x+w-1, height-y-1), fill=color(c))

    def text(font, c, px, x, y, value):
        draw.text((x, height-y), value, font=fonts[int(font)], fill=color(c), anchor='ls')

    lua.globals().paint_rect = rect
    lua.globals().paint_text = text
    lua.execute('''
        host.rect=function(_,x,y,w,h,c) paint_rect(x,y,w,h,c) end
        api.XPLMFontDrawString=function(f,c,px,x,y,t,j)
            paint_text(tonumber(ffi.cast('intptr_t',f)),c,px,x,y,t)
        end
        d:draw()
    ''')
    dest = ROOT / '.tools/dialog-previews' / f'{page}-{language}-{width}.png'
    dest.parent.mkdir(parents=True, exist_ok=True)
    im.save(dest)
    print(dest)


if __name__ == '__main__':
    for language in ('zh', 'en'):
        for page in ('general', 'position', 'colors', 'fonts', 'tools', 'records'):
            render(page, language, 900 if page == 'records' else 860)
    render('records', 'en', 520, 820)
    render('colors', 'en', 520, 820)
