"""Embed pinned map renderer and editable RC5 map module in both standalone HTMLs."""
from pathlib import Path
import json,base64,re,hashlib
R=Path(__file__).resolve().parents[1];V=R/'vendor/maplibre-gl-5.6.2'
for name,expected in json.loads((V/'source.json').read_text(encoding='utf-8'))['files'].items():
 assert hashlib.sha256((V/name).read_bytes()).hexdigest()==expected,'Vendored map asset changed: '+name
html=(R/'LMM_Report_Reader.html').read_text(encoding='utf-8')
def replace(start,end,content):
 global html
 pattern=re.escape(start)+r'[\s\S]*?'+re.escape(end)
 assert re.search(pattern,html),start
 html=re.sub(pattern,lambda _:start+'\n'+content+'\n'+end,html,count=1)
replace('/* LMM_MAP_CSS_BEGIN */','/* LMM_MAP_CSS_END */',(V/'maplibre-gl.css').read_text(encoding='utf-8')+'\n'+(R/'tools/analyzer/plan_map.css').read_text(encoding='utf-8'))
replace('// LMM_MAP_JS_BEGIN','// LMM_MAP_JS_END',(R/'tools/analyzer/plan_map.js').read_text(encoding='utf-8'))
bundle=json.dumps({'version':'5.6.2','license':(V/'LICENSE.txt').read_text(encoding='utf-8'),'js':base64.b64encode((V/'maplibre-gl.js').read_bytes()).decode()},ensure_ascii=True)
replace('<!-- LMM_MAP_VENDOR_BEGIN -->','<!-- LMM_MAP_VENDOR_END -->','<script type="application/json" id="lmm-maplibre-bundle">'+bundle+'</script>')
(R/'LMM_Report_Reader.html').write_text(html,encoding='utf-8')
(R/'Starlux_Analyzer_落地分析器.html').write_text(html.replace('starlux-lmm-reader-','starlux-lmm-standalone-reader-').replace('<title>StarLux LMM 分析器</title>','<title>StarLux Analyzer · 落地分析器</title>'),encoding='utf-8')
print('Map assets embedded; no external script or stylesheet dependency.')
