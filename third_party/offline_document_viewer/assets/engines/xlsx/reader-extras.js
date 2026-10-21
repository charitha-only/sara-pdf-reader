/* Sara reader: cached OOXML chart previews and safe conditional formatting.
   Publication formulas are never executed. Unsupported rules/charts are reported. */
(function(global) {
  'use strict';
  const parse = s => new DOMParser().parseFromString(s, 'application/xml');
  const all = (n, name) => Array.from(n.getElementsByTagNameNS('*', name));
  const first = (n,name) => all(n,name)[0];
  const esc = v => String(v).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  const color = n => n && /^[A-Fa-f0-9]{6,8}$/.test(n.getAttribute('rgb') || '') ? '#'+n.getAttribute('rgb').slice(-6) : null;
  const resolve = (base, ref) => new URL(ref, 'https://local/'+base).pathname.slice(1);
  async function xml(zip,path) { const f=zip.file(path); return f ? parse(await f.async('string')) : null; }
  async function rels(zip,path) {
    const slash=path.lastIndexOf('/'), doc=await xml(zip,path.slice(0,slash+1)+'_rels/'+path.slice(slash+1)+'.rels');
    const result={};
    if(doc)all(doc,'Relationship').forEach(r=>{ if(r.getAttribute('TargetMode')!=='External')result[r.getAttribute('Id')]=resolve(path,r.getAttribute('Target')); });
    return result;
  }
  function values(node, part, workbook) {
    const root=first(node,part); if(!root)return [];
    // Use explicit point indices; omitted points must not shift later values.
    const points=all(root,'pt').slice(0,500), out=[];
    points.forEach(p=>{ const i=Number(p.getAttribute('idx'));if(i>=0&&i<500)out[i]=first(p,'v')?.textContent || ''; });
    if (!out.length && workbook) {
      const formula=first(root,'f')?.textContent || '';
      const ref=/^(?:'((?:[^']|'')+)'|([^!]+))!\$?([A-Z]+)\$?([0-9]+)(?::\$?([A-Z]+)\$?([0-9]+))?$/.exec(formula);
      if (ref && !formula.includes('[')) {
        const sheet=workbook.Sheets[(ref[1]||ref[2]).replace(/''/g,"'")];
        const col=s=>Array.from(s).reduce((n,c)=>n*26+c.charCodeAt(0)-64,0);
        const name=n=>{let s='';while(n>0){n--;s=String.fromCharCode(65+n%26)+s;n=Math.floor(n/26);}return s;};
        if(sheet)for(let r=+ref[4];r<=+(ref[6]||ref[4]) && out.length<500;r++)for(let c=col(ref[3]);c<=col(ref[5]||ref[3]) && out.length<500;c++)out.push(sheet[name(c)+r]?.v ?? '');
      }
    }
    return out;
  }
  const palette=['#276FBF','#E8792D','#299A72','#A24B9D','#D6A11C','#556677'];
  function chartSvg(doc,workbook) {
    const plot=first(doc,'plotArea');if(!plot)return {html:'',supported:false};
    const kind=['barChart','lineChart','pieChart','doughnutChart'].find(k=>first(plot,k));
    const title=first(doc,'title');
    const label=title?all(title,'t').map(t=>t.textContent).join(' '):'Chart';
    if(!kind)return {html:'<p class="chart-note">'+esc(label)+': this chart type is not supported.</p>',supported:false};
    const chart=first(plot,kind),series=all(chart,'ser').slice(0,8).map((s,i)=>({
      name:values(s,'tx',workbook).join('')||first(s,'tx')?.textContent||'Series '+(i+1),
      categories:values(s,'cat',workbook), values:values(s,'val',workbook).map(v=>v==null?null:Number(v))
    }));
    if(!series.some(s=>s.values.some(v=>Number.isFinite(v))))return {html:'<p class="chart-note">'+esc(label)+': saved chart values are unavailable.</p>',supported:false};
    const count=Math.min(100,Math.max(...series.map(s=>s.values.length))), width=640,height=300;
    let svg='<svg xmlns="http://www.w3.org/2000/svg" role="img" aria-label="'+esc(label)+'" viewBox="0 0 '+width+' '+height+'">';
    const isPie=kind==='pieChart'||kind==='doughnutChart';
    if(isPie) {
      const vals=series[0].values.slice(0,count).map(v=>Math.max(0,Number.isFinite(v)?v:0)),total=vals.reduce((a,b)=>a+b,0);
      let angle=-Math.PI/2;
      if(total>0)vals.forEach((v,i)=>{
        if(!v)return;
        const next=angle+v/total*Math.PI*2, x1=320+110*Math.cos(angle),y1=145+110*Math.sin(angle),x2=320+110*Math.cos(next),y2=145+110*Math.sin(next);
        if(v===total)svg+='<circle cx="320" cy="145" r="110" fill="'+palette[i%palette.length]+'"/>';
        else svg+='<path fill="'+palette[i%palette.length]+'" d="M320 145 L'+x1+' '+y1+' A110 110 0 '+(next-angle>Math.PI?1:0)+' 1 '+x2+' '+y2+' Z"/>';
        angle=next;
      });
      if(kind==='doughnutChart')svg+='<circle cx="320" cy="145" r="55" fill="white"/>';
    } else {
      const nums=series.flatMap(s=>s.values.slice(0,count)).filter(v=>Number.isFinite(v));
      const minimum=Math.min(0,...nums),maximum=Math.max(1,...nums),range=maximum-minimum;
      const y=v=>250-(v-minimum)/range*210,step=550/Math.max(1,count),baseline=y(0);
      for(let i=0;i<=4;i++){const val=minimum+range*i/4,yy=y(val);svg+='<path stroke="#ddd" d="M60 '+yy+' H620"/><text x="55" y="'+(yy+4)+'" text-anchor="end" font-size="11">'+esc(Number(val.toPrecision(4)))+'</text>';}
      series.forEach((s,j)=>{
        if(kind==='lineChart') {
          const points=s.values.slice(0,count).map((v,i)=>Number.isFinite(v)?(60+(i+.5)*step)+','+y(v):'').filter(Boolean).join(' ');
          svg+='<polyline fill="none" stroke="'+palette[j%palette.length]+'" stroke-width="2" points="'+points+'"/>';
        } else s.values.slice(0,count).forEach((v,i)=>{
          if(!Number.isFinite(v))return;
          const w=step*.8/series.length,x=60+i*step+step*.1+j*w;
          svg+='<rect x="'+x+'" y="'+Math.min(y(v),baseline)+'" width="'+Math.max(.2,w)+'" height="'+Math.abs(y(v)-baseline)+'" fill="'+palette[j%palette.length]+'"/>';
        });
      });
      const labels=series[0].categories;
      for(let i=0;i<count;i+=Math.max(1,Math.ceil(count/8)))svg+='<text x="'+(60+(i+.5)*step)+'" y="278" text-anchor="middle" font-size="11">'+esc(String(labels[i]??(i+1)).slice(0,14))+'</text>';
    }
    svg+='</svg>';
    let legend='<ul class="chart-legend">';
    (isPie?series[0].values.slice(0,count).map((v,i)=>({name:series[0].categories[i]??String(i+1),color:palette[i%palette.length]})):series.map((s,i)=>({name:s.name,color:palette[i%palette.length]}))).forEach(s=>{legend+='<li><span style="color:'+s.color+'">●</span> '+esc(s.name)+'</li>';});
    legend+='</ul>';
    const partial=kind==='barChart'&&first(chart,'grouping')?.getAttribute('val')!=='clustered';
    return {html:'<figure class="reader-chart"><figcaption>'+esc(label)+'</figcaption>'+svg+legend+'<small>Saved chart values; '+(partial?'grouped preview of stacked/other bar layout.':'preview layout may differ.')+'</small></figure>',supported:true};
  }
  async function charts(zip,sheetPath,workbook) {
    const sheet=await xml(zip,sheetPath);if(!sheet)return {html:'',unsupported:0};
    const sheetRels=await rels(zip,sheetPath),parts=[];
    let unsupported=0;
    for(const drawing of all(sheet,'drawing').slice(0,12)) {
      const id=drawing.getAttribute('r:id')||drawing.getAttributeNS('http://schemas.openxmlformats.org/officeDocument/2006/relationships','id');
      const path=sheetRels[id];if(!path)continue;
      const doc=await xml(zip,path);if(!doc)continue;
      const links=await rels(zip,path);
      for(const c of all(doc,'chart').slice(0,12)) {
        const cid=c.getAttribute('r:id')||c.getAttributeNS('http://schemas.openxmlformats.org/officeDocument/2006/relationships','id');
        const target=links[cid];if(!target)continue;
        const chart=await xml(zip,target);if(!chart)continue;
        const rendered=chartSvg(chart,workbook);parts.push(rendered.html);if(!rendered.supported)unsupported++;
      }
    }
    return {html:parts.join(''),unsupported};
  }
  async function conditional(zip,path) {
    const doc=await xml(zip,path),styles=await xml(zip,'xl/styles.xml');
    if(!doc)return ()=>'';
    const dxfs=styles?all(styles,'dxf'):[];
    const rules=all(doc,'conditionalFormatting').flatMap(n=>all(n,'cfRule').map(rule=>({rule,ranges:(n.getAttribute('sqref')||'').split(/\s+/)}))).slice(0,500);
    const address=s=>{const m=/^\$?([A-Z]+)\$?(\d+)$/.exec(s);if(!m)return null;let c=0;for(const v of m[1])c=c*26+v.charCodeAt(0)-64;return {c:c-1,r:+m[2]-1};};
    const inside=(addr,ref)=>{const p=address(addr),ends=ref.split(':'),a=address(ends[0]),b=address(ends[1]||ends[0]);return p&&a&&b&&p.r>=a.r&&p.r<=b.r&&p.c>=a.c&&p.c<=b.c;};
    function dxfCss(n){if(!n)return '';let s='';const f=first(n,'font'),fill=first(n,'patternFill'),bg=fill&&color(first(fill,'fgColor'));if(bg)s+='background-color:'+bg+';';if(f){const fg=color(first(f,'color'));if(fg)s+='color:'+fg+';';if(first(f,'b'))s+='font-weight:bold;';if(first(f,'i'))s+='font-style:italic;';}return s;}
    const formatCell = (addr,cell,ws)=>{
      if(!cell)return '';
      let css='';
      for(const item of rules){
        if(!item.ranges.some(r=>inside(addr,r)))continue;
        const rule=item.rule,type=rule.getAttribute('type'),v=Number(cell.v),f=all(rule,'formula').map(n=>Number(n.textContent));
        let match=false;
        if(type==='cellIs'&&Number.isFinite(v)&&f.every(Number.isFinite)) {
          const a=f[0],b=f[1];
          match=({greaterThan:()=>v>a,greaterThanOrEqual:()=>v>=a,lessThan:()=>v<a,lessThanOrEqual:()=>v<=a,equal:()=>v===a,notEqual:()=>v!==a,between:()=>v>=a&&v<=b,notBetween:()=>v<a||v>b}[rule.getAttribute('operator')]||(()=>false))();
        } else if(type==='containsText')match=String(cell.v??'').toLowerCase().includes((rule.getAttribute('text')||'').toLowerCase());
        else if((type==='colorScale'||type==='dataBar')&&Number.isFinite(v)) {
          const container=first(rule,type),colors=all(container,'color').map(color).filter(Boolean),limits=all(container,'cfvo');
          if (!item.stats) {
            let lo=Infinity,hi=-Infinity;
            for(const k of Object.keys(ws)) { if(k[0]==='!'||!item.ranges.some(r=>inside(k,r)))continue;const n=Number(ws[k].v);if(Number.isFinite(n)){lo=Math.min(lo,n);hi=Math.max(hi,n);} }
            item.stats={lo,hi};
          }
          if(!Number.isFinite(item.stats.lo))continue;
          const bound=(n,fallback)=>n?.getAttribute('type')==='num'?Number(n.getAttribute('val')):fallback;
          const min=bound(limits[0],item.stats.lo),max=bound(limits[limits.length-1],item.stats.hi),ratio=max>min?Math.max(0,Math.min(1,(v-min)/(max-min))):.5;
          if(type==='dataBar'&&colors[0])css+='background-image:linear-gradient(to right,'+colors[0]+' '+Math.round(ratio*100)+'%,transparent '+Math.round(ratio*100)+'%);';
          else if(colors.length>=2){const seg=ratio*(colors.length-1),index=Math.min(colors.length-2,Math.floor(seg)),t=seg-index,a=colors[index],b=colors[index+1];const rgb=[1,3,5].map(i=>Math.round(parseInt(a.slice(i,i+2),16)*(1-t)+parseInt(b.slice(i,i+2),16)*t));css+='background-color:rgb('+rgb.join(',')+');';}
        }
        if(match){css+=dxfCss(dxfs[+rule.getAttribute('dxfId')]);if(rule.getAttribute('stopIfTrue')==='1')break;}
      }
      return css;
    };
    formatCell.hasRules = rules.length > 0;
    return formatCell;
  }
  global.ReaderExcelExtras={charts,conditional};
})(window);
