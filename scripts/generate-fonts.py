"""Generate embedded Manrope fonts from the canonical upstream source file.
uv run --with fonttools python scripts/generate-fonts.py SOURCE_TTF
"""
import base64,hashlib,io,sys
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools import subset
source=Path(sys.argv[1]);target=Path(__file__).resolve().parents[1]/'services/invoicing/src/fonts.ts'
parts=['// Generated Manrope subsets. OFL license: ../MANROPE-OFL.txt.', '// Upstream: google/fonts ofl/manrope; source SHA256 '+hashlib.sha256(source.read_bytes()).hexdigest()]
for name,weight in [('REGULAR',400),('BOLD',700)]:
 font=instantiateVariableFont(TTFont(source),{'wght':weight},inplace=True)
 options=subset.Options();options.layout_features=['*'];subsetter=subset.Subsetter(options=options)
 subsetter.populate(unicodes=list(range(0x20,0x250))+list(range(0x2000,0x2070))+[0x20AC,0x2122]);subsetter.subset(font)
 data=io.BytesIO();font.save(data)
 parts.append('export const MANROPE_'+name+'_B64='+repr(base64.b64encode(data.getvalue()).decode())+';')
target.write_text('\n'.join(parts)+'\n');print('Embedded Manrope regular/bold generated with Czech glyph coverage')
