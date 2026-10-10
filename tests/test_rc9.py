"""Bounded RC9 scheduling, report equivalence and warm popup layout."""
import unittest
import test_ui_119 as base
import test_recording_119 as recording

class RC9Tests(unittest.TestCase):
    def test_foreground_timing_cannot_starve_background_exports(self):
        l=base.runtime();l.execute('''
            local clock=0;local m=dofile(ROOT..'LMM_UI_119/core_work.lua').new(function()return clock end)
            m:begin_frame(1,1/20,false);clock=.02
            m:record('analysis',0);m:record('popup_draw',0)
            assert(m.used==0 and not m.slow_until and m:claim(),'foreground starved export')
            m:begin_frame(2,1/20,false);clock=.03;m:record('report_write',.02)
            assert(not m:claim(),'slow background work exceeded frame allowance')
            m:begin_frame(2.1,1/20,false);assert(m.bytes==1024 and m:claim(),'slow disk safety lost')
        ''')

    def test_pending_notice_uses_popup_completion_row_and_finishes_on_commit(self):
        l=base.RecorderTests().load_recorder();l.execute('''
            local rec=ui.recording;local jobs=getup(ui.process_report_build,'landing_jobs')
            local notice=getup(ui.start_report_flash,'landing_report_notice')
            local runtime=getup(ui.report_export_notice_text,'runtime_state')
            assert(not ui.report_export_notice_text())
            rec.id='flight';rec.file={};rec.touch_time=1
            ui.live.dismissed=true;ui.touchdown.dismissed=true
            assert(ui.report_export_notice_text()=='报告导出中，请勿关闭游戏')
            notice.ready=true;ui.start_report_flash(2)
            assert(not ui.report_flash_state(2),'early summary claimed complete flight')
            local drawn={};draw_string=function(x,y,text)drawn[#drawn+1]=text end
            ui.draw_database_status(1920,1080,2)
            for _,text in ipairs(drawn)do assert(text~='报告导出中，请勿关闭游戏','export notice leaked outside popup')end
            ui.native_initialize();ui.live.state='result'
            assert(ui.native_popup(true,2))
            local host=ui.native_ui.instance
            local row=#host.frame.lines;local width,height=host.layout.width,host.layout.height
            assert(host.frame.lines[row]=='报告导出中，请勿关闭游戏')
            rec.file=nil;rec.closed=true;jobs.report_build={}
            assert(ui.report_export_status()=='pending')
            jobs.report_build=nil;rec.export={phase='commit'}
            assert(ui.report_export_status()=='pending','close before commit cleared warning')
            rec.export_failed=true
            assert(ui.report_export_status()=='failed' and ui.report_export_notice_text():find('失败'))
            rec.export_failed=false;rec.export=nil;rec.closed=false;rec.saved_path='complete.txt'
            assert(not ui.report_export_notice_text());ui.start_report_flash(3)
            assert(ui.report_flash_state(3),'completed report did not become ready')
            notice.text='落地报告已生成';ui.native_popup(true,3)
            assert(#host.frame.lines==row and host.frame.lines[row]=='落地报告已生成','completion did not replace pending row')
            assert(host.layout.width==width and host.layout.height==height,'status replacement resized popup')
            ui.popup_style.renderer='legacy';ui.live.dismissed=false;ui.touchdown.dismissed=false
            getup(ma_landing_meter_draw,'show_until',99,true)
            local positions={};ui.draw_popup_text=function(x,y,text)
                if text=='报告导出中，请勿关闭游戏' or text=='落地报告已生成' then positions[#positions+1]={x,y,text}end
            end
            rec.saved_path=nil;rec.closed=true;ma_landing_meter_draw()
            rec.closed=false;rec.saved_path='complete.txt';notice.flash_started_at=0;ui.start_report_flash(1);ma_landing_meter_draw()
            assert(#positions==2 and positions[1][3]=='报告导出中，请勿关闭游戏' and positions[2][3]=='落地报告已生成')
            assert(positions[1][1]==positions[2][1] and positions[1][2]==positions[2][2],'legacy status changed position')
            rec.saved_path=nil;rec.file={};rec.touch_time=nil;ui.reset_report_notice()
            assert(not ui.report_export_notice_text(),'new approach inherited pending message')
            rec.touch_time=5;ui.native_ui.force_compatibility=true
            assert(ui.report_export_notice_text()=='Exporting report - please do not close X-Plane')
            runtime.replay_active=true;assert(not ui.report_export_notice_text())
            rec.file=nil
        ''')

    def test_static_report_sections_reused_without_changing_content(self):
        l=base.RecorderTests().load_recorder();l.execute('''
            for _,language in ipairs({'zh','en'})do
                ui.set_global_language(language)
                local ok,baseline=ui.build_landing_log_payload('cache.txt');assert(ok)
                local ok,a=ui.build_landing_log_payload('cache.txt',nil,{});assert(ok)
                local cache=ui.report_static_cache;assert(cache and a.content==baseline.content)
                local ok,b=ui.build_landing_log_payload('cache.txt',nil,{});assert(ok)
                assert(ui.report_static_cache==cache and b.content==baseline.content)
                ui.dev.inputs.sequence=ui.dev.inputs.sequence+1
                ui.build_landing_log_payload('cache.txt',nil,{})
                assert(ui.report_static_cache~=cache)
            end
        ''')

    def test_adaptive_export_pages_survive_slow_io(self):
        f=recording.RecordingTests();f.setUp();self.addCleanup(f.doCleanups)
        f.lua.execute('''
            rec:tick(sample(1),1);rec:tick(sample(1.1),1);rec:stop('manual_end',false)
            local pages={};for i=1,40 do pages[i]=string.rep('中文-data-',200)..i..'\\n' end
            rec:attach_summary(pages,OUT..'adaptive.txt')
            local timer=0;rec.work=dofile(ROOT..'LMM_UI_119/core_work.lua').new(function()return timer end)
            rec:begin_export();local out=rec.export.out;local lengths={}
            rec.export.out={write=function(_,s)lengths[#lengths+1]=#s;timer=timer+.01;return out:write(s)end,
                close=function()return out:close()end}
            for i=1,2000 do
                rec.work:begin_frame(10+i/15,1/15,false);rec:export_step()
                if rec.saved_path then break end
            end
            assert(rec.saved_path and rec.work.stats.export.max>=.009)
            for i,n in ipairs(lengths)do assert(n<=(i==1 and 8192 or 1024)) end
            local file=assert(io.open(rec.saved_path,'rb'));local value=file:read('*a');file:close()
            assert(value:find(table.concat(pages),1,true),'segmented UTF-8 prefix corrupted')
            assert(value:find('LMM_RECORDING_END',1,true),'complete flight body missing')
        ''')

    def test_slow_io_feedback_throttles_without_starving(self):
        l=base.runtime();l.execute('''
            local clock=0;local m=dofile(ROOT..'LMM_UI_119/core_work.lua').new(function()return clock end)
            m:begin_frame(1,1/120,false);clock=.02;m:record('export',0)
            m:begin_frame(1.1,1/120,false);assert(m.bytes==1024 and m.rows==4 and m:claim())
            m:begin_frame(1.6,1/120,false);assert(m.bytes==32768)
            assert(m.stats.export.max==.02 and m.stats.export.bins[6]==1)
        ''')

    def test_yielded_math_report_preserves_flight_scratch(self):
        l=base.RecorderTests().load_recorder();l.execute('''
            ui.recording.id='a';ui.recording.report_path='scratch.txt'
            local analysis=getup(ma_landing_meter_update,'landing_analysis');analysis.math_log_enabled=true
            ui.begin_incremental_landing_log_write(true)
            local scratch=getup(ui.process_report_build,'sort_scratch')
            scratch[1]=12345
            getup(ui.process_report_build,'sort_scratch_count',1,true)
            for i=1,2000 do
                ui.work:begin_frame(i/15,1/15,false);ui.process_report_build()
                assert(getup(ui.process_report_build,'sort_scratch')==scratch and scratch[1]==12345)
                assert(getup(ui.process_report_build,'sort_scratch_count')==1)
                if ui.recording.summary then break end
            end
            assert(type(ui.recording.summary)=='table')
        ''')

    def test_soft_budget_protection_recovery_and_progress(self):
        l=base.runtime();l.execute('''
            local m=dofile(ROOT..'LMM_UI_119/core_work.lua').new(function()return 0 end)
            m:begin_frame(10,1/60,true);assert(not m:claim())
            m:begin_frame(10.49,1/60,false);assert(not m:claim())
            m:begin_frame(10.51,1/60,false);assert(m:claim() and not m:claim())
            m:begin_frame(11,1/15,false);assert(m.bytes==8192 and m.rows==16 and m:claim())
            m:begin_frame(12,1/120,false);assert(m.bytes<32768,'recovery must be gradual')
            m:begin_frame(1,1/60,false);assert(m:claim(),'rewind must not leave guard stuck')
        ''')

    def test_segmented_report_matches_sync_chinese_english_and_debug_appendix(self):
        for lang in ['zh','en']:
            l=base.RecorderTests().load_recorder()
            l.globals().lang=lang
            l.execute('''
                ui.set_global_language(lang)
                getup(ma_landing_meter_update,'landing_analysis').math_log_enabled=true
                local ok,expected=ui.build_landing_log_payload('same.txt');assert(ok)
                ui.work.clock=function()return 0 end
                local task=ui.work:build(ui.build_landing_log_payload,'same.txt','stable')
                local result,n
                for i=1,2000 do
                    ui.work:begin_frame(i/15,1/15,false)
                    local state,value=ui.work:step(task)
                    assert(state~='error',value)
                    if state=='done' then result=value;n=i;break end
                end
                assert(result and n>10,'report should yield repeatedly even on fast CPUs')
                assert(table.concat(result.content)==expected.content,'incremental report differs')
                local size=0;for _,p in ipairs(result.content)do assert(#p<=4096);size=size+#p end
                assert(size==result.length)
            ''')

    def test_revision_restart_and_session_cancel(self):
        l=base.RecorderTests().load_recorder();l.execute('''
            ui.recording.id='a';ui.recording.report_path='a.txt'
            ui.begin_incremental_landing_log_write(true)
            local jobs=getup(ui.process_report_build,'landing_jobs');local first=jobs.report_build
            ui.work:begin_frame(1,1/60,false);ui.process_report_build()
            ui.touchdown.serial=ui.touchdown.serial+1
            ui.work:begin_frame(2,1/60,false);ui.process_report_build()
            assert(jobs.report_build~=first and jobs.report_build.session=='a')
            ui.recording.id='b'
            ui.work:begin_frame(3,1/60,false);ui.process_report_build()
            assert(not jobs.report_build and not ui.recording.summary,'mixed flight report leaked')
        ''')

    def test_popup_prepared_layout_reused_and_caches_bounded(self):
        l=base.RecorderTests().load_recorder();l.execute('''
            ui.native_initialize();local h=ui.native_ui.instance
            ui.live.state='recording';ui.work:begin_frame(1,1/60,false)
            ui.prewarm_popup();local measures=calls.measures
            local reserve=ui.full_popup_reserve()
            h:present({lines=reserve,reserve=reserve,size=ui.popup_style.font_px,
                vertical=getup(ma_landing_meter_draw,'POPUP_LAYOUT')=='vertical',position=function()return 0,0 end,
                color={0,0,0},text_color={1,1,1},alpha=1})
            assert(calls.measures==measures,'touchdown still remeasured prepared layout')
            ui.live.state='touchdown';ui.touchdown:start(1);ui.touchdown:update(1,1.4,-1,0,0,1,0,false)
            assert(ui.native_popup(true,1.1))
            assert(calls.measures==measures,'actual popup path missed prepared layout')
            for i=1,2000 do h:measure('value '..i,14)end
            assert(h.width_count<=1024)
        ''')

    def test_report_atomic_visibility_and_chunk_budget(self):
        l=base.RecorderTests().load_recorder();l.execute('''
            ui.recording.id='a';local jobs=getup(ui.process_report_build,'landing_jobs')
            writes={};renames=0
            io.open=function(path,mode)
                assert(path=='result.txt.summary.tmp' and mode=='wb')
                return {write=function(self,s)writes[#writes+1]=#s;return self end,close=function()return true end}
            end
            os.rename=function(a,b)assert(a=='result.txt.summary.tmp' and b=='result.txt');renames=renames+1;return true end
            jobs.log_write={path='result.txt',recording_id='a',content={string.rep('a',4096),string.rep('b',4096),string.rep('c',100)},length=8292,page=1,offset=1,build_ms=0}
            for i=1,2 do
                ui.work:begin_frame(i,1/15,false);ui.process_incremental_landing_log_write(i)
                assert(renames==0 and writes[i]<=8192)
            end
            ui.work:begin_frame(3,1/15,false);ui.process_incremental_landing_log_write(3)
            assert(renames==1 and not jobs.log_write and #ui.recording.summary==3)
        ''')

if __name__=='__main__':unittest.main(verbosity=2)
