const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ctx={console,URL,Number,Math,JSON,Uint8Array,ArrayBuffer,TextDecoder,addEventListener(){},setTimeout,clearTimeout};ctx.window=ctx;
vm.createContext(ctx);vm.runInContext(fs.readFileSync('third_party/offline_document_viewer/assets/viewers/bridge.js','utf8'),ctx);
const fit=ctx.Bridge.fitScale;
assert.equal(fit('actual',960,540,400,700),1);
assert.equal(fit('2',960,540,400,700),2);
assert.equal(fit('3',200,100,400,700),3);
assert.equal(fit('width',1000,3000,500,600),.5);
assert.equal(fit('page',1000,3000,500,600),.2);
assert.equal(fit('page',0,3000,500,600),1);
assert.equal(fit('page',1000,3000,NaN,600),1);
assert.equal(fit('9999999',1000,3000,500,600),3);
assert.equal(fit('0.01',1000,3000,500,600),.1);
assert.equal(fit('0.25',1000,3000,500,600),.25);
for(const name of ['docx','xlsx','pptx','text'])assert.match(fs.readFileSync('third_party/offline_document_viewer/assets/viewers/'+name+'.js','utf8'),/Bridge.fitScale/);

// Execute the real Word/Excel shell handlers against bounded layout fixtures.
for (const name of ['docx', 'xlsx']) {
 const messages=[], styles={}, content={style:styles,scrollWidth:1500,scrollHeight:3000,
   getBoundingClientRect(){return {height:3000*Number(styles.zoom||1)}}};
 const page={offsetWidth:1500,offsetHeight:3000};
 const stage={style:{},clientWidth:360,getBoundingClientRect(){return {top:0}},
   querySelector(){return content},querySelectorAll(){return [page]}};
 const element=()=>({style:{},addEventListener(){},setAttribute(){},append(){},after(){}});
 const document={documentElement:{clientWidth:360},getElementById(id){return id==='stage'?stage:element()},createElement:element};
 const local={console,URL,Number,Math,JSON,Uint8Array,ArrayBuffer,TextDecoder,document,innerHeight:700,
   addEventListener(){},setTimeout,clearTimeout,
   flutter_inappwebview:{callHandler(channel,raw){messages.push(JSON.parse(raw))}}};
 local.window=local;vm.createContext(local);
 vm.runInContext(fs.readFileSync('third_party/offline_document_viewer/assets/viewers/bridge.js','utf8'),local);
 local.Bridge.start=()=>{};
 vm.runInContext(fs.readFileSync('third_party/offline_document_viewer/assets/viewers/'+name+'.js','utf8'),local);
 const set=mode=>local.Bridge.receive({type:'viewMode',payload:{mode}});
 set('width');assert.equal(messages.at(-1).type,'zoom');assert.equal(messages.at(-1).payload.scale,.24);
 set('0.25');assert.equal(Number(styles.zoom),.25);assert.equal(messages.at(-1).payload.scale,.25);
 set('page');assert.equal(messages.at(-1).payload.scale,684/3000);
 stage.clientWidth=300;document.documentElement.clientWidth=300;
 set('width');assert.equal(messages.at(-1).payload.scale,.2);
 assert.equal(page.offsetWidth,1500,'Zoom must preserve authored page geometry');
 const count=messages.length;local.Bridge.reportScale(NaN);local.Bridge.reportScale(99);assert.equal(messages.length,count);
}
console.log('Office original/numeric zoom, width/page fits and hostile dimension checks passed.');
