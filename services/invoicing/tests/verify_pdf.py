"""Decode the QR from actual Workerd PDF, including all pages/text/font bounds."""
from pathlib import Path
import fitz
import zxingcpp
from PIL import Image
root=Path(__file__).resolve().parents[3]/'private/invoicing-tests'
doc=fitz.open(root/'rendered.pdf');assert len(doc)>1
expected=(root/'expected-qr.txt').read_text()
qr=[]
for n,page in enumerate(doc):
 pix=page.get_pixmap(matrix=fitz.Matrix(3,3));img=Image.frombytes('RGB',[pix.width,pix.height],pix.samples)
 qr += [r.text for r in zxingcpp.read_barcodes(img)]
 text=page.get_text();assert f'strana {n+1}/{len(doc)}' in text
 for block in page.get_text('dict')['blocks']:
  for line in block.get('lines',[]):
   for span in line['spans']:
    x0,y0,x1,y1=span['bbox'];assert 0<=x0<x1<=596 and 0<=y0<y1<=842,(n,span)
assert expected in qr,(expected,qr)
first_text=doc[0].get_text()
assert 'Číslo faktury: TEST-2026-000001' in first_text
assert 'Účet: 19-2000145399/0800' in first_text
assert 'IBAN: CZ6508000000192000145399' in first_text
assert 'Variabilní symbol: 00012345' in first_text
simulation=fitz.open(root/'simulation.pdf');simulation_text=simulation[0].get_text()
for value in ['SIMULACE - NEPLATIT','Číslo faktury: TEST-2026-000001','Účet: 19-2000145399/0800','IBAN: CZ6508000000192000145399']:
 assert value in simulation_text,value
pix=simulation[0].get_pixmap(matrix=fitz.Matrix(3,3));img=Image.frombytes('RGB',[pix.width,pix.height],pix.samples)
assert 'SIMULATION - NOT A PAYMENT' in [r.text for r in zxingcpp.read_barcodes(img)]
assert '4938' in ''.join(page.get_text() for page in doc).replace(' ','').replace(',','.')
print(f'Workerd PDF: {len(doc)} pages, Czech text bounds and SPAYD decoded')
