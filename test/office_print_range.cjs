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
 const wb=ctx.XLSX.utils.book_new();const sheet=ctx.XLSX.utils.aoa_to_sheet([['Title','Amount'],['A',42]]);
 sheet.A488={t:'s',v:'Outside print'};sheet['!ref']='A1:Y488';sheet['!merges']=[{s:{r:0,c:0},e:{r:0,c:1}}];
 ctx.XLSX.utils.book_append_sheet(wb,sheet,'Data');wb.Workbook={Names:[{Name:'_xlnm.Print_Area',Sheet:0,Ref:'Data!$A$1:$T$43'}]};
 const rendered=await ctx.XlsxRender.render(ctx.XLSX.write(wb,{type:'array',bookType:'xlsx'}));
 const one=rendered.sheets[0];assert.equal(one.printArea,'A1:T43');assert.equal((one.printHtml.match(/<tr/g)||[]).length,43);assert.match(one.html,/Outside print/);assert.doesNotMatch(one.printHtml,/Outside print/);assert.match(one.printHtml,/colspan="2"/);
 console.log('Synthetic print-range, merged-cell and full-sheet preservation checks passed.');
})().catch(e=>{console.error(e);process.exitCode=1});
