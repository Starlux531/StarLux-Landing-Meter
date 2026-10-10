"""Local LuaJIT CPU benchmark. Does not measure X-Plane FPS or GPU cost."""
import json
from time import perf_counter_ns
from pathlib import Path
from test_ui_119 import runtime, ROOT

l=runtime()
l.execute('''
    local M=dofile(ROOT..'LMM_UI_119/core_touchdown.lua');local m=M.new()
    function batch()
        m:start(0)
        for i=0,720 do m:update(i/240,1.2+.1*math.sin(i/20),-1,0,0,1,0,false) end
    end
    function prepare_finish()
        m:start(0)
        for i=0,710 do m:update(i/240,1.2+.1*math.sin(i/20),-1,0,0,1,0,false) end
    end
    function finish_event()m:finish(710/240,'velocity_settled')end
    function memory_check()
    collectgarbage();local before=collectgarbage('count')
    for j=1,100 do
        m:start(0);for i=0,720 do m:update(i/240,1.3,-1,0,0,1,0,false) end;m:close(true)
    end
    collectgarbage();heap_delta_kib=collectgarbage('count')-before
    max_samples=m.count
    end
''')
batch,prepare,finish=l.globals().batch,l.globals().prepare_finish,l.globals().finish_event
for _ in range(30):batch();prepare();finish()
updates,finishes=[],[]
for _ in range(100):
    start=perf_counter_ns();batch();updates.append((perf_counter_ns()-start)/1000/721)
    prepare();start=perf_counter_ns();finish();finishes.append((perf_counter_ns()-start)/1e6)
l.globals().memory_check()
def summary(table):
    a=sorted(table)
    return dict(mean=sum(a)/len(a),p95=a[int(len(a)*.95)],max=max(a))
result={'scope':'Warm LuaJIT observer; simulated 240 Hz; 100 runs; high-resolution host timer (includes call boundary); no live simulator/GPU',
        'batch_average_update_us_including_completion':summary(updates),
        'event_finish_ms':summary(finishes),
        'retained_heap_delta_kib_after_100_landings':l.globals().heap_delta_kib,
        'samples_per_3s_event':l.globals().max_samples}
assert result['samples_per_3s_event']<=1024
assert result['retained_heap_delta_kib_after_100_landings']<128
target=ROOT/'.tools/rc6/performance.json';target.parent.mkdir(parents=True,exist_ok=True)
target.write_text(json.dumps(result,indent=2),encoding='utf8')
print(json.dumps(result,indent=2))
