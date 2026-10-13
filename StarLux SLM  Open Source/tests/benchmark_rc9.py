"""Offline RC8/RC9 layout comparison; measures SDK-double calls, not game FPS."""
import json,time
from pathlib import Path
from test_ui_119 import ROOT,RecorderTests

l=RecorderTests().load_recorder()
backup=ROOT/'旧版备份/2026-10-09_RC9开发前_114731/LMM_UI_119/layout.lua'
l.globals().BEFORE=backup.read_text(encoding='utf-8-sig')
l.execute('''
    before=assert(loadstring(BEFORE))();after=dofile(ROOT..'LMM_UI_119/layout.lua')
    ui.native_initialize();local host=ui.native_ui.instance
    lines=ui.full_popup_reserve()
    function layout_run(module)
        local n=0
        local function measure(s,px)n=n+3;return countchars(s)*px*.75 end
        local function metrics(px)return px*.95,px*.25,px*1.2 end
        module.build(lines,14,1900,1040,false,metrics,measure)
        return n
    end
''')
result={'scope':'offline same 9-row popup including centerline, mocked font widths; no GPU / X-Plane', 'layout':{}}
for name in ['before','after']:
    samples=[]
    for _ in range(100):
        start=time.perf_counter_ns();calls=l.globals().layout_run(l.globals()[name]);samples.append((time.perf_counter_ns()-start)/1e6)
    samples.sort();result['layout'][name]={'font_measure_calls':calls,'mean_ms':sum(samples)/len(samples),'p95_ms':samples[94]}
l.execute('''
    ui.live.state='recording';ui.work:begin_frame(1,1/60,false);ui.prewarm_popup()
    local host=ui.native_ui.instance;local count=calls.measures
    host:present({lines=lines,reserve=lines,size=ui.popup_style.font_px,
        vertical=getup(ma_landing_meter_draw,'POPUP_LAYOUT')=='vertical',position=function()return 0,0 end,
        color={0,0,0},text_color={1,1,1},alpha=1})
    warm_calls=calls.measures-count
''')
result['prepared_touchdown_layout_measure_calls']=l.globals().warm_calls
dest=ROOT/'.tools/rc9';dest.mkdir(exist_ok=True)
(dest/'performance.json').write_text(json.dumps(result,indent=2),encoding='utf8')
print(json.dumps(result,indent=2))
