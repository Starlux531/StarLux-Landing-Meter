const {modernFixture}=require('./test_unified_reader.cjs');
function ilsFixture(mode='full'){
 const meta={ils_version:'1',ils_loc_lat:25,ils_loc_lon:121.031,ils_loc_course_true:90,ils_loc_id:'ITST',ils_airport:'TEST',ils_runway:'09',ils_loc_deg_per_dot:1.25,ils_gs_deg_per_dot:.35};
 if(mode!=='locOnly')Object.assign(meta,{ils_gs_lat:25,ils_gs_lon:121.003,ils_gs_elevation_m:30.48,ils_gs_angle_deg:3});
 let raw=modernFixture();if(mode==='none')return raw;
 return raw.replace('META\tstart_time',Object.entries(meta).map(([key,v])=>`META\t${key}\t${v}\n`).join('')+'META\tstart_time');
}
module.exports={ilsFixture};
