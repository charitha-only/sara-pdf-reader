const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {DOMParser}=require('@xmldom/xmldom');
const base=require('node:path').join(__dirname,'../third_party/offline_document_viewer/assets/engines/xlsx/');
const sample=new DOMParser().parseFromString('<r/>','application/xml');
const proto=Object.getPrototypeOf(sample.documentElement);
if(!('children' in proto)) Object.defineProperty(proto,'children',{get(){return Array.from(this.childNodes||[]).filter(x=>x.nodeType===1);}});
const ctx={URL,console,DOMParser,TextDecoder,Uint8Array,ArrayBuffer,setTimeout,clearTimeout};ctx.window=ctx;
vm.createContext(ctx);
for(const file of ['xlsx.full.min.js','jszip3.min.js','reader-extras.js','xlsx-render.js'])vm.runInContext(fs.readFileSync(base+file,'utf8'),ctx,{filename:file});
(async()=>{
 const wb=ctx.XLSX.utils.book_new();ctx.XLSX.utils.book_append_sheet(wb,ctx.XLSX.utils.aoa_to_sheet([['Bounded preview']]),'Data');
 const original=ctx.XLSX.write(wb,{type:'array',bookType:'xlsx'});
 const zip=await ctx.JSZip.loadAsync(original);
 let xml=await zip.file('xl/worksheets/sheet1.xml').async('string');
 xml=xml.replace(/<dimension ref="[^"]*"\/>/,'<dimension ref="A1:XFD1048576"/>');
 xml=xml.replace('</worksheet>','<mergeCells count="10001">'+ '<mergeCell ref="A1:XFD1048576"/>'.repeat(10001)+'</mergeCells></worksheet>');
 zip.file('xl/worksheets/sheet1.xml',xml);
 const bytes=await zip.generateAsync({type:'arraybuffer'});
 const started=Date.now();const result=await ctx.XlsxRender.render(bytes);const sheet=result.sheets[0];
 assert.equal(sheet.truncated,true);assert.ok(sheet.rows*sheet.cols<=60000);assert.ok(sheet.html.length<100000);assert.ok(Date.now()-started<10000,'Pathological merges must have bounded work');
 const many=ctx.XLSX.utils.book_new();many.Workbook={Names:[]};
 for(let index=0;index<12;index++){
  ctx.XLSX.utils.book_append_sheet(many,ctx.XLSX.utils.aoa_to_sheet([['Tiny sheet']]),'Sheet'+index);
  many.Workbook.Names.push({Name:'_xlnm.Print_Area',Sheet:index,Ref:'Sheet'+index+'!$A$1:$GR$3000'});
 }
 const printed=await ctx.XlsxRender.render(ctx.XLSX.write(many,{type:'array',bookType:'xlsx'}));
 const totalCells=printed.sheets.reduce((sum,s)=>sum+(s.html.match(/<td /g)||[]).length+(s.printHtml?s.printHtml.match(/<td /g)||[]:[]).length,0);
 assert.ok(totalCells<=250000,'Print previews must share the workbook cell budget');
 assert.ok(printed.sheets.some(s=>s.truncated));
 console.log('Resource limits passed: giant worksheet range and 10,001 overlapping full-sheet merges are bounded.');
})().catch(e=>{console.error(e);process.exitCode=1});
