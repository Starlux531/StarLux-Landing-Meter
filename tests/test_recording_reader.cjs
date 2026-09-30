const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../LMM_Report_Reader.html'),'utf8');
const code=html.slice(html.indexOf('function parseFullRecording('),html.indexOf('function integrateRecording('));
const ctx=vm.createContext({});vm.runInContext(code,ctx);
const parse=text=>ctx.parseFullRecording(text);
const fixture='LMM_RECORDING_BEGIN\t1\nFIELDS\tT\tt\tlat\tlon\tpitch_input\tpitch_source\nFIELDS\tW\tt\tspeed_kt\tsource\nMETA\tfront_missing\t1\nT\t1\t25\t121\t0\tsim/yoke\nT\t1.1\t25\t121\t\t\nW\t1\t10\tcockpit2_instrument\nE\t1.05\tinput_source\tpitch\nauto';
const valid=fixture.slice(0,fixture.lastIndexOf('\nauto'))+'\nLMM_RECORDING_END\t1\t2\n';
assert.equal(parse('legacy report'),null);
const record=parse(valid);assert(record.complete);assert.equal(record.trajectory.length,2);assert.equal(record.trajectory[0].pitch_input,0);assert.equal(record.trajectory[1].pitch_input,null);assert.equal(record.trajectory[0].pitch_source,'sim/yoke');
assert.equal(parse('old short table 1.2 3.4\n'+valid).trajectory.length,2,'do not merge the short excerpt');
for(const [content,issue] of [[valid.replace('LMM_RECORDING_END\t1\t2',''),'missing_end'],[valid.replace('LMM_RECORDING_END\t1\t2','LMM_RECORDING_END\t1\t3'),'sample_count'],[valid.replace('T\t1.1','T\t1'),'invalid_time_or_value'],[valid.replace('T\t1.1\t25\t121\t\t','T\t1.1\t25'),'truncated_row'],[valid.replace('BEGIN\t1','BEGIN\t2'),'unsupported_version'],[valid+'T\t2\t25\t121\t0\tx','trailing_data']]){
  const r=parse(content);assert(!r.complete);assert(r.issues.includes(issue),JSON.stringify(r.issues));
}
assert.equal(ctx.recordingPointAt(record.trajectory,.9),null);
assert.equal(ctx.recordingPointAt(record.trajectory,1.05).t,1);
const long=Array.from({length:50000},(_,i)=>({t:i*.1,g:i===13333?4.5:1}));
const reduced=ctx.recordingEnvelope(long,'g');assert(reduced.length<=3604);assert(reduced.some(p=>p.g===4.5),'preserve brief G peak');
long[13334].g=null;assert(ctx.recordingEnvelope(long,'g').some(p=>p.g===null),'retain missing-data break');
assert(ctx.recordingEnvelope([{t:1,g:1},{t:10,g:1}],'g').some(p=>p.g===null),'short records also retain time gaps');
console.log('Full recording: legacy, zero vs missing, integrity/version checks, independent timeline, cursor and peak-preserving reduction passed.');
if(process.argv[2]){
  const actual=parse(fs.readFileSync(process.argv[2],'utf8'));
  assert(actual&&actual.complete,JSON.stringify(actual?.issues));assert.equal(actual.trajectory.length,18001);assert(actual.wind.length>=1800);
  console.log('Actual Lua-generated 30-minute file: 18,001 trajectory rows and complete wind rows parsed successfully.');
}
