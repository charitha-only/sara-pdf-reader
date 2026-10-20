package app.pageflow.reader

import android.util.Base64
import org.apache.poi.hwpf.HWPFDocument
import org.apache.poi.hwpf.converter.WordToHtmlConverter
import org.apache.poi.hwpf.usermodel.CharacterRun
import org.apache.poi.hwpf.usermodel.Range
import org.apache.poi.hwpf.usermodel.Table
import org.apache.poi.hwpf.HWPFDocumentCore
import org.apache.poi.hwpf.model.FIBFieldHandler
import org.apache.poi.util.LittleEndian
import org.w3c.dom.Element
import java.io.ByteArrayInputStream
import java.io.StringWriter
import javax.xml.transform.TransformerFactory
import javax.xml.transform.OutputKeys
import javax.xml.transform.dom.DOMSource
import javax.xml.transform.stream.StreamResult

/** Converts legacy Word tables, runs and inline images locally; never uploads. */
object LegacyWordRenderer {
    fun render(bytes: ByteArray): String {
        require(bytes.size <= 20 * 1024 * 1024) { "Legacy Word preview supports files up to 20 MB." }
        HWPFDocument(ByteArrayInputStream(bytes)).use { doc ->
            // Android's DOM exposes snapshot NodeLists. POI's compaction requires
            // W3C live NodeLists; use Xerces to avoid removing detached nodes.
            val dom = org.apache.xerces.jaxp.DocumentBuilderFactoryImpl().newDocumentBuilder().newDocument()
            val boxes = textboxRanges(doc)
            val converter = object : WordToHtmlConverter(dom) {
                override fun processDrawnObject(document: HWPFDocument, run: CharacterRun, block: Element) {
                    val drawing = document.officeDrawingsMain.getOfficeDrawingAt(run.startOffset)
                    val range = drawing?.let { boxes[it.shapeId] }
                    if (range == null) { super.processDrawnObject(document, run, block); return }
                    val anchor = dom.createElement("span")
                    anchor.setAttribute("id", "word-anchor-${drawing.shapeId}")
                    block.appendChild(anchor)
                    val box = dom.createElement("div")
                    box.setAttribute("class", "word-textbox")
                    box.setAttribute("data-anchor", "word-anchor-${drawing.shapeId}")
                    box.setAttribute("data-left", (drawing.rectangleLeft / 20.0).toString())
                    box.setAttribute("data-top", (drawing.rectangleTop / 20.0).toString())
                    box.setAttribute("style", "display:block;position:relative;margin-left:${drawing.rectangleLeft/20.0}pt;width:${(drawing.rectangleRight-drawing.rectangleLeft)/20.0}pt;min-height:${(drawing.rectangleBottom-drawing.rectangleTop)/20.0}pt;border:0.5pt solid black;padding:4pt;background:white;")
                    dom.getElementsByTagName("body").item(0).appendChild(box)
                    processParagraphes(document, box, range, Int.MIN_VALUE)
                }
                override fun processTable(document: HWPFDocumentCore, flow: Element, table: Table) {
                    super.processTable(document, flow, table)
                    val element = flow.lastChild as? Element ?: return
                    val props = table.getParagraph(0).props
                    val section = document.range.getSection(0)
                    if (props.dxaAbs > 0) {
                        val row = table.getRow(0)
                        val width = (0 until row.numCells()).sumOf { row.getCell(it).width }
                        val right = (section.pageWidth - section.marginRight - props.dxaAbs - row.getCell(0).leftEdge - width)/20.0
                        element.setAttribute("style", "float:right;margin-right:${maxOf(0.0,right)}pt;")
                    } else {
                        element.setAttribute("style", "clear:both;margin-left:auto;margin-right:auto;")
                    }
                }
            }
            converter.setPicturesManager { content, type, _, _, _ ->
                val mime = when(type.extension.lowercase()) {
                    "png" -> "image/png"
                    "jpg", "jpeg" -> "image/jpeg"
                    "gif" -> "image/gif"
                    "bmp" -> "image/bmp"
                    else -> "application/octet-stream"
                }
                "data:$mime;base64," + Base64.encodeToString(content, Base64.NO_WRAP)
            }
            converter.processDocument(doc)
            dom.getElementsByTagName("body").item(0).let { (it as Element).setAttribute("data-page-width", (doc.range.getSection(0).pageWidth/20.0*96/72).toString()) }
            val output = StringWriter()
            val serializer = TransformerFactory.newInstance().newTransformer()
            serializer.setOutputProperty(OutputKeys.METHOD, "html")
            serializer.setOutputProperty(OutputKeys.ENCODING, "UTF-8")
            serializer.transform(DOMSource(converter.document), StreamResult(output))
            return output.toString()
        }
    }

    /** MS-DOC 2.8.32: CP array followed by 22-byte FTXBXS entries. */
    private fun textboxRanges(doc: HWPFDocument): Map<Int, Range> {
        val main = doc.mainStream
        fun shortAt(offset: Int): Int { require(offset >= 0 && offset+2 <= main.size); return LittleEndian.getUShort(main,offset) }
        var cursor = 32
        cursor += 2 + shortAt(cursor)*2
        cursor += 2 + shortAt(cursor)*4
        val count = shortAt(cursor)
        val entry = cursor + 2 + FIBFieldHandler.PLCFTXBXTXT*8
        if (FIBFieldHandler.PLCFTXBXTXT >= count || entry+8 > main.size) return emptyMap()
        val offset = LittleEndian.getInt(main,entry)
        val size = LittleEndian.getInt(main,entry+4)
        val table = doc.tableStream
        if (size < 4 || (size-4)%26 != 0 || offset < 0 || offset.toLong()+size > table.size) return emptyMap()
        val n = (size-4)/26
        require(n <= 10000) { "Too many text boxes." }
        val base = doc.mainTextboxRange
        val boxes = mutableMapOf<Int, Range>()
        for (i in 0 until n-1) {
            val cp1 = LittleEndian.getInt(table,offset+i*4)
            val cp2 = LittleEndian.getInt(table,offset+(i+1)*4)
            val record = offset+(n+1)*4+i*22
            val reusable = LittleEndian.getUShort(table,record+8)
            val shapeId = LittleEndian.getInt(table,record+14)
            if (reusable == 0 && cp1 >= 0 && cp2 > cp1 && cp2 <= base.endOffset-base.startOffset) {
                boxes[shapeId] = Range(base.startOffset+cp1,base.startOffset+cp2,doc)
            }
        }
        return boxes
    }
}
