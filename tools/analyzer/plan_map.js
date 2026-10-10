// RC5: one optional map, no log upload. Static geography is separate from the timeline cursor.
const planMap = {
  map:null, report:null, enabled:true, visible:false, time:null, frame:0, dirty:true, failed:false,
  stats:{staticDraws:0,cursorDraws:0,created:0},
  mercator(lat,lon){const a=clamp(lat,-85.05112878,85.05112878)*Math.PI/180;return {x:(lon+180)/360,y:(1-Math.log(Math.tan(Math.PI/4+a/2))/Math.PI)/2}},
  longitude(lon){return this.anchor+longitudeDelta(lon-this.anchor)},
  project(p){return this.map.project([this.longitude(p.lon),clamp(p.lat,-85.05112878,85.05112878)])},
  text(){
    $('planMapLabel').querySelector('span').textContent=tr('OSM 底图','OSM basemap');
    $('planExpand').textContent=$('planDialog').open?tr('↙ 返回页面','↙ Restore'):tr('⛶ 单独放大','⛶ Expand view');
    $('mapRetry').textContent=tr('重试底图','Retry basemap');
    $('planMapNote').textContent=tr('底图由 OpenFreeMap 按当前显示区域提供，日志保留本地。仅作复盘参考，地景跑道与 OpenStreetMap 底图可能不同。','OpenFreeMap receives requests for the displayed map area; logs stay local. Replay reference only: scenery runways may differ from OpenStreetMap.');
    if(this.enabled)$('planHelp').textContent=tr('地图北向朝上；拖动平移，Ctrl + 滚轮或 + / − 缩放。悬停航迹定位时间，不自动移动或缩放地图。全程俯视恢复完整路线；Esc 退出放大。','North up. Drag to pan; Ctrl + wheel or + / − to zoom. Hover over the track to seek without moving or zooming the map. Overview fits the full track; Esc closes the expanded view.');
    this.status($('planMapToggle').disabled?'nogeo':this.failed?'failed':this.map?(this.ready?'ready':'loading'):'off');
    this.controls();
  },
  status(kind){
    $('mapState').hidden=!this.enabled;
    $('mapStateText').textContent=kind==='nogeo'?tr('此记录没有可用于底图的经纬度','No map-compatible coordinates in this record'):kind==='ready'?tr('北 ↑ · OSM 在线底图','N ↑ · OSM basemap'):kind==='failed'?tr('底图暂不可用，已保留轨迹视图','Basemap unavailable; track view retained'):kind==='loading'?tr('正在加载底图… 轨迹可继续查看','Loading basemap… Track remains available'):tr('OSM 底图 · 等待进入视区','OSM basemap · waiting for view');
    $('mapRetry').hidden=kind!=='failed';
    $('geoMap').hidden=!this.map;
    $('approachPlan').hidden=Boolean(this.map&&this.ready);
    $('geoMap').style.visibility=this.ready?'visible':'hidden';
  },
  controls(){
    const button=$('planPlay');if(!button)return;
    button.textContent=state.playback.playing?tr('❚❚ 暂停','❚❚ Pause'):tr('▶ 播放','▶ Play');
    button.setAttribute('aria-pressed',String(state.playback.playing));
    const d=playbackDomain(),t=state.playback.touched&&Number.isFinite(state.playback.time)?state.playback.time:Number.isFinite(this.time)?this.time:d.xmin;
    $('planTime').value=String(clamp((t-d.xmin)/Math.max(.001,d.xmax-d.xmin),0,1)*1000);
    $('planClock').textContent=`${timeLabel(t)} / ${timeLabel(d.xmax)}`;
    $('planTime').setAttribute('aria-label',tr('俯视图回放时间','Plan playback time'));
  },
  bind(report){
    if(this.report!==report){this.destroy();this.report=report;this.failed=false;this.camera=null;this.data=null;this.lastKey=null}
    $('planMapToggle').disabled=!(report.planPoints||[]).some(p=>Math.abs(p.lat)<85.05112878);
    this.text();this.start();
  },
  setEnabled(enabled){
    this.enabled=enabled;$('planMapToggle').checked=enabled;
    if(!enabled){this.destroy();this.failed=false;$('planZoom').value=String(this.svgZoom||1);this.text();renderApproachPlan(activeRecord().report);updatePlanViews(sharedHoverTime)}
    else{this.svgZoom=Number($('planZoom').value)||1;this.failed=false;this.text();this.start()}
  },
  library(){
    if(window.maplibregl)return;
    const asset=JSON.parse($('lmm-maplibre-bundle').textContent),script=document.createElement('script');
    script.textContent=new TextDecoder().decode(Uint8Array.from(atob(asset.js),c=>c.charCodeAt(0)));
    document.head.append(script);script.remove();
    if(!window.maplibregl)throw Error('Map renderer unavailable');
    maplibregl.setWorkerCount(2);
  },
  prepare(){
    if(this.data)return;
    const points=(this.report.planPoints||[]).filter(p=>Math.abs(p.lat)<85.05112878);
    this.anchor=points[0]?.lon||0;
    let west=Infinity,east=-Infinity,south=Infinity,north=-Infinity;
    const tree=planPickTree(points.map(p=>{const lon=this.longitude(p.lon);west=Math.min(west,lon);east=Math.max(east,lon);south=Math.min(south,p.lat);north=Math.max(north,p.lat);return {...this.mercator(p.lat,lon),p}}));
    const display=[],stride=Math.max(1,Math.ceil(points.length/4000));
    for(let i=0;i<points.length;i++){const gap=!i||points[i].t-points[i-1].t>1.1;
      if(gap||i%stride===0||i===points.length-1||points[i+1]?.t-points[i].t>1.1)display.push({p:points[i],gap})}
    const g=this.report.runwayGeometry;if(g)for(const p of [{lat:g.lat1,lon:g.lon1},{lat:g.lat2,lon:g.lon2}]){west=Math.min(west,this.longitude(p.lon));east=Math.max(east,this.longitude(p.lon));south=Math.min(south,p.lat);north=Math.max(north,p.lat)}
    this.data={points,display,tree,bounds:[[west-.0003,south-.0003],[east+.0003,north+.0003]]};
  },
  start(){
    if(!this.enabled||!this.visible||this.map||this.failed||!this.report||$('planMapToggle').disabled)return;
    try{
      this.library();this.prepare();this.ready=false;$('geoMap').hidden=false;$('geoMap').style.visibility='hidden';
      const map=new maplibregl.Map({container:$('geoMap'),style:'https://tiles.openfreemap.org/styles/positron',
        bounds:this.camera?undefined:this.data.bounds,fitBoundsOptions:{padding:48,maxZoom:16,duration:0},
        ...(this.camera||{}),minZoom:2,maxZoom:19,pitch:0,bearing:0,scrollZoom:false,boxZoom:false,
        doubleClickZoom:false,dragRotate:false,touchZoomRotate:false,touchPitch:false,keyboard:false,
        renderWorldCopies:true,fadeDuration:0,maxTileCacheSize:64,maxTileCacheZoomLevels:2,
        pixelRatio:Math.min(window.devicePixelRatio||1,1.5),attributionControl:false,trackResize:false,
        localIdeographFontFamily:'sans-serif',canvasContextAttributes:{antialias:false,preserveDrawingBuffer:false}});
      this.map=map;this.stats.created++;this.status('loading');
      const attribution=document.createElement('div');attribution.className='map-credit';attribution.innerHTML='<a href="https://openfreemap.org/" target="_blank" rel="noopener">OpenFreeMap</a> · <a href="https://openmaptiles.org/" target="_blank" rel="noopener">© OpenMapTiles</a> · <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">© OpenStreetMap contributors</a>';$('geoMap').append(attribution);
      map.addControl(new maplibregl.ScaleControl({maxWidth:110,unit:'metric'}),'bottom-left');
      this.staticCanvas=document.createElement('canvas');this.cursorCanvas=document.createElement('canvas');
      for(const c of [this.staticCanvas,this.cursorCanvas]){c.className='map-track-layer';c.setAttribute('aria-hidden','true');map.getCanvasContainer().append(c)}
      this.staticCanvas.dataset.mapTrack='true';this.cursorCanvas.dataset.mapCursor='true';
      this.deadline=setTimeout(()=>{if(this.map===map&&!this.ready)this.fail()},20000);
      map.on('load',()=>{if(this.map!==map)return;clearTimeout(this.deadline);this.ready=true;this.failed=false;this.status('ready');this.resize();if(!this.camera)map.fitBounds(this.data.bounds,{padding:48,maxZoom:16,duration:0});this.baseZoom=map.getZoom();if(!this.camera)map.jumpTo({zoom:clamp(this.baseZoom+Math.log2(.71),2,19)});this.syncZoom();this.dirty=true;this.schedule()});
      map.on('error',event=>{if(this.map!==map)return;this.lastError=String(event.error?.message||'Map request failed');if(!map.isStyleLoaded())this.fail();else{this.partial=true;$('mapStateText').textContent=tr('部分底图未加载；轨迹不受影响','Some map tiles unavailable; track remains visible')}});
      map.on('idle',()=>{if(this.map===map&&this.ready&&map.areTilesLoaded()){this.partial=false;this.status('ready')}});
      map.on('move',()=>{this.dirty=true;this.schedule()});
      map.on('zoomend',()=>this.syncZoom());
      map.on('dragstart',()=>{cancelHover();pausePlayback()});
      map.on('mousemove',event=>{if(map.isMoving())return;queueHover(e=>this.seek(e.clientX,e.clientY),{clientX:event.point.x,clientY:event.point.y})});
      map.on('mouseout',cancelHover);map.on('click',event=>{cancelHover();this.seek(event.point.x,event.point.y)});
      map.getCanvas().addEventListener('wheel',event=>{if(!event.ctrlKey)return;event.preventDefault();event.stopPropagation();cancelHover();
        const rect=map.getCanvas().getBoundingClientRect(),x=(event.clientX-rect.left)/rect.width*map.getContainer().clientWidth,y=(event.clientY-rect.top)/rect.height*map.getContainer().clientHeight;
        map.easeTo({zoom:clamp(map.getZoom()+(event.deltaY>0?-.5:.5),2,19),around:map.unproject([x,y]),duration:0})},{passive:false});
      map.getCanvas().addEventListener('webglcontextlost',()=>{if(this.map===map){this.lastError='WebGL context lost';this.fail()}},{once:true});
    }catch(error){this.lastError=String(error?.message||error);this.fail()}
  },
  fail(){this.destroy();this.failed=true;this.ready=false;$('planZoom').value=String(this.svgZoom||1);this.status('failed')},
  destroy(){
    cancelHover();clearTimeout(this.deadline);cancelAnimationFrame(this.frame);this.frame=0;
    const map=this.map;this.map=null;this.ready=false;
    if(map){this.camera={center:map.getCenter().toArray(),zoom:map.getZoom()};map.remove()}
    $('geoMap').replaceChildren();$('geoMap').hidden=true;$('approachPlan').hidden=false;
    this.lastKey=null;this.dirty=true;
  },
  resize(){if(!this.map)return;this.map.resize();this.dirty=true;this.schedule()},
  syncZoom(){if(!this.map||!Number.isFinite(this.baseZoom))return;const value=(2**(this.map.getZoom()-this.baseZoom)).toFixed(2),select=$('planZoom');let custom=$('mapZoomValue');if(!custom){custom=document.createElement('option');custom.id='mapZoomValue';select.append(custom)}custom.value=value;custom.textContent=value+'×';select.value=value},
  zoom(factor,absolute){
    if(!this.enabled||!this.map||!this.ready)return false;
    cancelHover();const map=this.map;
    if(absolute&&factor===1){map.fitBounds(this.data.bounds,{padding:48,maxZoom:16,duration:0});this.baseZoom=map.getZoom()}
    else map.jumpTo({zoom:clamp(absolute?this.baseZoom+Math.log2(factor):map.getZoom()+Math.log2(factor),2,19)});
    this.syncZoom();
    return true;
  },
  nearest(x,y){
    const ll=this.map.unproject([x,y]),q=this.mercator(ll.lat,this.longitude(ll.lng));let best=null,distance=Infinity;
    const lower=n=>Math.max(n.minx-q.x,0,q.x-n.maxx)**2+Math.max(n.miny-q.y,0,q.y-n.maxy)**2;
    const visit=n=>{if(!n||lower(n)>distance)return;if(n.items){for(const p of n.items){const d=(p.x-q.x)**2+(p.y-q.y)**2;if(d<distance){distance=d;best=p.p}}return}
      const first=lower(n.left)<lower(n.right)?n.left:n.right;visit(first);visit(first===n.left?n.right:n.left)};
    visit(this.data.tree);if(best){const p=this.project(best);if(Math.hypot(p.x-x,p.y-y)>36)return null}return best;
  },
  seek(x,y){if(!this.map||!this.ready)return;const p=this.nearest(x,y);if(p){pausePlayback();if(sharedHoverTime!==p.t)setPlaybackTime(p.t,true,false)}},
  update(time){
    this.time=time;this.controls();if(!this.map||!this.ready)return;
    const p=recordingPointAt(this.data.points,time),valid=p&&time-p.t<=1.1,w=windAtTime(this.report,time);
    $('approachNow').textContent=`T+ ${time.toFixed(2)} s · ${valid?`${p.lat.toFixed(5)}°, ${p.lon.toFixed(5)}°`:tr('位置不可用','Position unavailable')} · ${valid&&Number.isFinite(p.cross)?tr('中线左向 ','Left of centerline ')+p.cross.toFixed(1)+' m · ':''}${w?tr('风来自 ','Wind from ')+windDirectionText(w)+' / '+w.speed_kt.toFixed(1)+' kt':tr('风数据不可用','Wind unavailable')}`;
    const d=chartTimeDomain(this.report,comparisonRecord()?.report),key=`${d.xmin}/${d.xmax}/${$('planWind').checked}`;
    if(key!==this.lastKey){this.dirty=true;this.lastKey=key}this.schedule();
  },
  schedule(){if(this.frame||!this.visible||document.hidden)return;this.frame=requestAnimationFrame(()=>{this.frame=0;if(!this.map||!this.ready)return;if(this.dirty){this.drawStatic();this.dirty=false}this.drawCursor()})},
  context(canvas){
    const w=this.map.getContainer().clientWidth,h=this.map.getContainer().clientHeight,dpr=Math.min(devicePixelRatio||1,1.5);
    if(canvas.width!==Math.round(w*dpr)||canvas.height!==Math.round(h*dpr)){canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr)}
    const ctx=canvas.getContext('2d');ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,w,h);return ctx;
  },
  line(ctx,points,color,width,dash=[]){ctx.beginPath();points.forEach((p,i)=>{const q=this.project(p);i?ctx.lineTo(q.x,q.y):ctx.moveTo(q.x,q.y)});ctx.strokeStyle=color;ctx.lineWidth=width;ctx.setLineDash(dash);ctx.stroke();ctx.setLineDash([])},
  arrow(ctx,p,w,alpha=.38){const q=this.project(p),v=windVector(w,null);if(!v||!(w.speed_kt>0))return;ctx.save();ctx.globalAlpha=alpha;ctx.strokeStyle=windColor(w.speed_kt);ctx.lineWidth=2;ctx.stroke(new Path2D(windArrowPath(q.x,q.y,v.x,v.y,w.speed_kt)));ctx.restore()},
  drawStatic(){
    this.stats.staticDraws++;const ctx=this.context(this.staticCanvas),report=this.report,g=report.runwayGeometry,d=chartTimeDomain(report,comparisonRecord()?.report);
    this.lastKey=`${d.xmin}/${d.xmax}/${$('planWind').checked}`;
    if(g){
      const at=(along,cross)=>({lat:g.lat1+(g.uy*along+g.ux*cross)/111195,lon:g.lon1+(g.ux*along-g.uy*cross)/(111195*g.cos)});
      const corners=[at(0,-g.width/2),at(g.length,-g.width/2),at(g.length,g.width/2),at(0,g.width/2),at(0,-g.width/2)];
      this.line(ctx,corners,'#d4deec',1.5);ctx.fillStyle='#98acc833';ctx.fill();
      this.line(ctx,[at(-8000,0),at(g.length,0)],'#b8ccdf99',1,[6,6]);
      if(Number.isFinite(g.touchLat)&&Number.isFinite(g.touchLon)){const q=this.project({lat:g.touchLat,lon:g.touchLon});ctx.beginPath();ctx.arc(q.x,q.y,6,0,Math.PI*2);ctx.fillStyle='#ffcb73';ctx.fill();ctx.strokeStyle='#23182c';ctx.lineWidth=2;ctx.stroke();ctx.font='bold 11px sans-serif';ctx.fillText('TD',q.x+10,q.y-7)}
    }
    const ils=report.ilsReference;
    if(ils){const a=ils.course*Math.PI/180;this.line(ctx,[ils,{lat:ils.lat-Math.cos(a)*18*1852/111195,lon:ils.lon-Math.sin(a)*18*1852/(111195*Math.cos(ils.lat*Math.PI/180))}],'#d6a2efaa',2,[9,6])}
    const trace=(windowOnly,color,width)=>{ctx.beginPath();let active=false;for(const {p,gap} of this.data.display){if(windowOnly&&(p.t<d.xmin||p.t>d.xmax)){active=false;continue}const q=this.project(p);if(gap||!active)ctx.moveTo(q.x,q.y);else ctx.lineTo(q.x,q.y);active=true}ctx.lineWidth=width;ctx.strokeStyle=color;ctx.stroke()};
    ctx.lineCap='round';trace(false,'#08151ddd',6);trace(false,'#77dbe3aa',3);trace(true,'#77f2f5',3.5);
    if($('planWind').checked){let last=null,count=0;const winds=timeWindowPoints(report.recording?.wind||[],{xmin:d.xmin+report.recordingStart,xmax:d.xmax+report.recordingStart});
      for(const w of winds){const t=w.t-report.recordingStart,p=recordingPointAt(this.data.points,t);if(!p||t-p.t>1.1)continue;const q=this.project(p);
        if(q.x<10||q.y<20||q.x>this.staticCanvas.clientWidth-10||q.y>this.staticCanvas.clientHeight-35||last&&Math.hypot(q.x-last.x,q.y-last.y)<30)continue;
        this.arrow(ctx,p,w);last=q;if(++count>=90)break}
    }
  },
  drawCursor(){
    this.stats.cursorDraws++;const ctx=this.context(this.cursorCanvas),p=recordingPointAt(this.data.points,this.time);
    if(!p||!Number.isFinite(this.time)||this.time-p.t>1.1)return;
    const q=this.project(p);ctx.save();ctx.strokeStyle='#ffe9ad99';ctx.lineWidth=1;ctx.setLineDash([4,5]);ctx.beginPath();ctx.moveTo(0,q.y);ctx.lineTo(this.cursorCanvas.clientWidth,q.y);ctx.stroke();ctx.restore();
    ctx.beginPath();ctx.arc(q.x,q.y,7,0,Math.PI*2);ctx.fillStyle='#fff4d1';ctx.strokeStyle='#198da6';ctx.lineWidth=3;ctx.fill();ctx.stroke();
    if($('planWind').checked){const w=windAtTime(this.report,this.time);if(w)this.arrow(ctx,p,w,.65)}
  }
};
function initPlanMapUI(){
  // RC9 launch defaults apply to existing installs too; unrelated saved preferences are untouched.
  planMap.enabled=true;
  for(const id of ['planMapToggle','planWind','showWindProfile'])$(id).checked=true;
  state.profileMode='wind';
  $('planMapToggle').addEventListener('change',e=>planMap.setEnabled(e.target.checked));
  $('mapRetry').addEventListener('click',()=>{planMap.failed=false;planMap.start()});
  $('planPlay').addEventListener('click',togglePlayback);
  $('planTime').addEventListener('input',e=>{pausePlayback();const d=playbackDomain();setPlaybackTime(d.xmin+(d.xmax-d.xmin)*Number(e.target.value)/1000,true,false)});
  const dialog=$('planDialog'),module=$('planModule'),home=$('planHome');
  $('planExpand').addEventListener('click',()=>{
    cancelHover();if(dialog.open){dialog.close();return}
    dialog.append(module);dialog.showModal();document.body.classList.add('plan-expanded');planMap.visible=true;planMap.text();planMap.start();requestAnimationFrame(()=>planMap.resize());$('planExpand').focus();
  });
  dialog.addEventListener('close',()=>{home.append(module);document.body.classList.remove('plan-expanded');planMap.text();requestAnimationFrame(()=>planMap.resize());$('planExpand').focus()});
  new ResizeObserver(()=>{if(planMap.map)planMap.resize()}).observe($('planStage'));
  new IntersectionObserver(entries=>{planMap.visible=entries[0].isIntersecting;if(planMap.visible){planMap.start();planMap.schedule()}},{rootMargin:'0px'}).observe($('planStage'));
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)planMap.schedule()});
}
