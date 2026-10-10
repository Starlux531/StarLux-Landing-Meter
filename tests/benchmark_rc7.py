"""Warm CPU-only presentation benchmark, not a simulator FPS measurement."""
from time import perf_counter_ns
import json
from test_ui_119 import ROOT,runtime
l=runtime();l.execute('''
    local live=dofile(ROOT..'LMM_UI_119/core_live.lua').new()
    local td={};local rec={file={},id='flight'};local t=0
    live:sync(rec,td,false,0,false)
    function batch()
        for i=1,1000 do
            t=t+1/120
            live:update(t,-650+30*math.sin(t),-640,2000-t*10,false,false,'plane')
            live:sync(rec,td,false,t,false)
            live:line(1,true);live:line(2,true);live:line(3,true)
        end
    end
''')
batch=l.globals().batch
for _ in range(20):batch()
a=[]
for _ in range(100):
    t=perf_counter_ns();batch();a.append((perf_counter_ns()-t)/1e6)
a.sort();result={'scope':'warm LuaJIT presentation; 100 batches of 1000 frames; includes call boundary; no GPU or simulator',
    'average_microseconds_per_frame':sum(a)/len(a),'p95_batch_average_us_per_frame':a[95],
    'source_read_calls_added':0,'disk_samples_added':0}
(ROOT/'.tools/rc7/performance.json').write_text(json.dumps(result,indent=2),encoding='utf8')
print(json.dumps(result,indent=2))
