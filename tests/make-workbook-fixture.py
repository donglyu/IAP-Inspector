"""A compressed, shared-string XLSX fixture; no spreadsheet runtime required."""
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('xl/workbook.xml', '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="业务数据" r:id="rId1"/></sheets></workbook>')
    z.writestr('xl/_rels/workbook.xml.rels', '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>')
    z.writestr('xl/sharedStrings.xml', '<sst><si><t>订单号</t></si><si><t>transactionId</t></si><si><t>1234567890123456789</t></si><si><r><t>rich</t></r><r><t> text</t></r></si></sst>')
    z.writestr('xl/worksheets/sheet1.xml', '<worksheet><sheetData>'
                '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>'
                '<row r="2"><c r="A2" t="s"><v>3</v></c><c r="C2" t="s"><v>2</v></c></row>'
                '<row r="3"><c r="C3"><v>1234567890123456789</v></c></row>'
                '<row r="4"><c r="C4"><v>1.23456789012345E+18</v></c></row>'
                '<row r="6"><c r="C6" t="str"><f>TEXT(123,"0")</f><v>123</v></c></row>'
                '</sheetData></worksheet>')
