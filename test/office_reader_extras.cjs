// NODE_PATH=<test-only @xmldom/xmldom installation>/node_modules node test/office_reader_extras.cjs
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {DOMParser}=require('@xmldom/xmldom');
const window={};
vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../third_party/offline_document_viewer/assets/engines/xlsx/reader-extras.js'),'utf8'),{window,DOMParser,URL,console});
const zip=files=>({file:name=>files[name]==null?null:{async:async()=>files[name]}});
const base={
 'xl/worksheets/sheet1.xml':'<worksheet xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><drawing r:id="draw1"/></worksheet>',
 'xl/worksheets/_rels/sheet1.xml.rels':'<Relationships><Relationship Id="draw1" Target="../drawings/drawing1.xml"/></Relationships>',
 'xl/drawings/drawing1.xml':'<drawing xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><chart r:id="chart1"/></drawing>',
 'xl/drawings/_rels/drawing1.xml.rels':'<Relationships><Relationship Id="chart1" Target="../charts/chart1.xml"/></Relationships>',
};
const series='<ser><tx><strRef><strCache><pt idx="0"><v>Sales</v></pt></strCache></strRef></tx><cat><strRef><strCache><pt idx="0"><v>A</v></pt><pt idx="1"><v>B</v></pt></strCache></strRef></cat><val><numRef><numCache><pt idx="0"><v>10</v></pt><pt idx="1"><v>20</v></pt></numCache></numRef></val></ser>';
(async()=>{
 for(const type of ['barChart','lineChart','pieChart','doughnutChart']){
  const chart='<chartSpace><chart><title><t>&lt;script&gt;</t></title><plotArea><'+type+'><grouping val="clustered"/>'+series+'</'+type+'></plotArea></chart></chartSpace>';
  const result=await window.ReaderExcelExtras.charts(zip({...base,'xl/charts/chart1.xml':chart}),'xl/worksheets/sheet1.xml');
  assert.equal(result.unsupported,0);assert.match(result.html,/<svg/);assert.match(result.html,/&lt;script&gt;/);assert.doesNotMatch(result.html,/<script>/);assert.doesNotMatch(result.html,/NaN|Infinity/);
 }
 const many=await window.ReaderExcelExtras.charts(zip({...base,'xl/charts/chart1.xml':'<chartSpace><plotArea><lineChart>'+series.repeat(8)+'</lineChart></plotArea></chartSpace>'}),'xl/worksheets/sheet1.xml'); assert.doesNotMatch(many.html,/undefined/);
 const noCache='<chartSpace><plotArea><barChart><grouping val="clustered"/><ser><cat><strRef><f>Data!$A$1:$A$2</f></strRef></cat><val><numRef><f>Data!$B$1:$B$2</f></numRef></val></ser></barChart></plotArea></chartSpace>';
 const fallback=await window.ReaderExcelExtras.charts(zip({...base,'xl/charts/chart1.xml':noCache}),'xl/worksheets/sheet1.xml',{Sheets:{Data:{A1:{v:'Alpha'},A2:{v:'Beta'},B1:{v:10},B2:{v:25}}}});
 assert.equal(fallback.unsupported,0);assert.match(fallback.html,/<svg/);assert.match(fallback.html,/Alpha/);
 const unsupported=await window.ReaderExcelExtras.charts(zip({...base,'xl/charts/chart1.xml':'<chartSpace><plotArea><radarChart/></plotArea></chartSpace>'}),'xl/worksheets/sheet1.xml');
 assert.equal(unsupported.unsupported,1);assert.match(unsupported.html,/not supported/);
 const conditional=await window.ReaderExcelExtras.conditional(zip({
  'xl/styles.xml':'<styleSheet><dxfs><dxf><font><b/><color rgb="FF990000"/></font><fill><patternFill><fgColor rgb="FFFFEEEE"/></patternFill></fill></dxf></dxfs></styleSheet>',
  'xl/worksheets/sheet1.xml':'<worksheet><conditionalFormatting sqref="A1:A4"><cfRule type="cellIs" dxfId="0" operator="greaterThan"><formula>10</formula></cfRule></conditionalFormatting><conditionalFormatting sqref="B1:B3"><cfRule type="dataBar"><dataBar><cfvo type="min"/><cfvo type="max"/><color rgb="FF112233"/></dataBar></cfRule></conditionalFormatting></worksheet>'
 }),'xl/worksheets/sheet1.xml');
 let scans=0;
 const cells={A1:{v:12},A2:{v:2},A3:{v:'=alert(1)'},B1:{v:0},B2:{v:50},B3:{v:100}};
 const ws=new Proxy(cells,{ownKeys(v){scans++;return Reflect.ownKeys(v);}});
 assert.match(conditional('A1',cells.A1,ws),/background-color:#FFEEEE;.*font-weight:bold/i);
 assert.equal(conditional('A2',cells.A2,ws),'');assert.equal(conditional('C1',{v:100},ws),'');
 assert.equal(conditional('A3',cells.A3,ws),'');
 for(let i=0;i<1000;i++)assert.match(conditional('B2',cells.B2,ws),/50%/);
 assert.equal(scans,1,'Conditional range statistics must be cached, not scanned for every cell');
 console.log('Excel reader checks passed: 4 chart types, escaping, unsupported charts, conditional formatting and cached range statistics.');
})().catch(e=>{console.error(e);process.exitCode=1;});
