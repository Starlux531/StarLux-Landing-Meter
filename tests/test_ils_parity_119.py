"""The same reference must give identical needles live and in offline replay."""
import json
import math
import random
import subprocess
import unittest
from pathlib import Path
from test_ui_119 import runtime


class ILSParityTests(unittest.TestCase):
    def test_lua_and_reader_geometry_agree(self):
        lua=runtime()
        lua.execute("I=assert(loadfile(ROOT..'LMM_UI_119/core_ils.lua'))()")
        rng=random.Random(1193)
        samples=[]
        for course in [0,90,226.727,359.8]:
            ref=dict(ils_version=1,ils_loc_lat=22.596677778,ils_loc_lon=108.161941667,
                     ils_loc_course_true=course,ils_loc_deg_per_dot=1.25,ils_gs_deg_per_dot=.35,
                     ils_gs_lat=22.615875,ils_gs_lon=108.185730556,ils_gs_elevation_m=1800,ils_gs_angle_deg=3.25)
            for i in range(30):
                c=math.radians(course);forward=rng.uniform(-40000,1000);right=rng.uniform(-4000,4000)
                point=dict(lat=ref['ils_loc_lat']+(forward*math.cos(c)-right*math.sin(c))/111195,
                           lon=ref['ils_loc_lon']+(forward*math.sin(c)+right*math.cos(c))/(111195*math.cos(math.radians(ref['ils_loc_lat']))),
                           msl=rng.uniform(5000,12000),ground=1 if i%13==0 else 0)
                result=lua.globals().I.geometry(lua.table_from(ref),lua.table_from(point))
                values={k:result[k] for k in ['loc_valid','gs_valid','loc_dots','gs_dots']}
                samples.append(dict(meta={k:str(v) for k,v in ref.items()},point=point,expected=values))
        script="""
const fs=require('fs'),vm=require('vm'),assert=require('assert/strict');
const html=fs.readFileSync('LMM_Report_Reader.html','utf8'),context=vm.createContext({state:{}});
vm.runInContext(html.slice(html.indexOf('function parseFullRecording('),html.indexOf('function setTimeView(')),context);
for(const s of JSON.parse(fs.readFileSync(0,'utf8'))){
 const got=context.ilsDeviation(context.parseIlsReference(s.meta),s.point);
 for(const key of ['loc_valid','gs_valid'])assert.equal(got[key],s.expected[key]);
 for(const key of ['loc_dots','gs_dots'])if(s.expected[key]!==null)assert(Math.abs(got[key]-s.expected[key])<1e-7,JSON.stringify({key,got,s}));
}
"""
        result=subprocess.run(['node','-e',script],input=json.dumps(samples),text=True,capture_output=True,cwd=Path(__file__).resolve().parents[1])
        self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__':unittest.main()
