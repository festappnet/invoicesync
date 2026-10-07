// Adapted from the Mendelio/pdf-lib renderer; integer immutable snapshots only.
import {PDFDocument,rgb,type PDFFont,type PDFPage} from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';
import QR from 'qrcode/lib/core/qrcode.js';
import {MANROPE_BOLD_B64,MANROPE_REGULAR_B64} from './fonts.ts';
import type {InvoiceCommand,BillingProfile} from '../../../packages/invoicing-client/src/index.ts';
export const RENDERER_VERSION='invoicing-4';
export interface Snapshot {simulation:boolean;brand_name:string;number:string;issued_on:string;due_on:string;issuer:BillingProfile;buyer:BillingProfile;owner_email:string;account:{iban:string;physical_account_id:string};reference:{normalized_vs:string;reservation_id:string};command:InvoiceCommand;total_minor:string;tax_regime:'non_vat'}
export function validIban(value:string){const iban=value.replace(/\s/g,'').toUpperCase();if(!/^CZ\d{22}$/.test(iban))throw Error('iban_invalid');if(BigInt((iban.slice(4)+iban.slice(0,4)).replace(/[A-Z]/g,c=>String(c.charCodeAt(0)-55)))%97n!==1n)throw Error('iban_invalid');return iban;}
const amount=(v:string)=>{if(!/^\d{1,12}$/.test(v))throw Error('amount_invalid');const n=BigInt(v);return `${n/100n}.${String(n%100n).padStart(2,'0')}`;};
const money=(v:string,english=false)=>{const s=amount(v).split('.');return english?s[0].replace(/\B(?=(\d{3})+(?!\d))/g,',')+'.'+s[1]+' CZK':s[0].replace(/\B(?=(\d{3})+(?!\d))/g,' ')+','+s[1]+' Kč';};
export function spayd(s:Snapshot){if(s.simulation)return 'SIMULATION - NOT A PAYMENT';if(!/^\d{1,10}$/.test(s.reference.normalized_vs)||s.tax_regime!=='non_vat'||!/^\d{4}-\d{2}-\d{2}$/.test(s.due_on))throw Error('payment_snapshot_invalid');return `SPD*1.0*ACC:${validIban(s.account.iban)}*AM:${amount(s.total_minor)}*CC:CZK*X-VS:${s.reference.normalized_vs}*DT:${s.due_on.replaceAll('-','')}`;}
const fontBytes=(s:string)=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
function wrap(font:PDFFont,value:string,width:number,size:number){
 if(/[\u0000-\u0008\u000b-\u001f]/.test(value))throw Error('unsupported_character');const supported=new Set(font.getCharacterSet());for(const c of value)if(c!=='\n'&&!supported.has(c.codePointAt(0)!))throw Error('unsupported_character');
 const result:string[]=[];for(const paragraph of value.split('\n')){let current='';const graphemes=[...new Intl.Segmenter('cs',{granularity:'grapheme'}).segment(paragraph)].map(x=>x.segment);for(const c of graphemes){if(font.widthOfTextAtSize(current+c,size)>width){const space=current.lastIndexOf(' ');if(space>0){result.push(current.slice(0,space).trimEnd());current=(current.slice(space+1)+c).trimStart();}else{result.push(current.trimEnd());current=c.trimStart();}}else current+=c;}result.push(current.trimEnd());}return result;
}
export interface BrandShape {path:string;fill:string;stroke?:string;stroke_width?:number}
export interface InvoiceBrand {name:string;view_box:number;email_logo_png?:string;wordmark_paths?:BrandShape[];paths:BrandShape[]}
export async function renderInvoice(s:Snapshot,brand?:InvoiceBrand):Promise<Uint8Array>{
 if(s.command.lines.length<1||s.command.lines.length>500)throw Error('document_too_large');const total=s.command.lines.reduce((sum,x)=>sum+BigInt(x.quantity)*BigInt(x.unit_minor),0n);if(total.toString()!==s.total_minor)throw Error('total_mismatch');
 const english=s.buyer.language==='en',label=(cs:string,en:string)=>english?en:cs,date=(value:string)=>new Intl.DateTimeFormat(english?'en-GB':'cs-CZ',{day:'numeric',month:'numeric',year:'numeric',timeZone:'Europe/Prague'}).format(new Date(value+'T12:00:00Z'));
 const pdf=await PDFDocument.create();pdf.registerFontkit(fontkit);pdf.setCreationDate(new Date(s.issued_on+'T00:00:00Z'));pdf.setModificationDate(new Date(s.issued_on+'T00:00:00Z'));pdf.setTitle(s.number);pdf.setProducer(RENDERER_VERSION);pdf.setCreator(RENDERER_VERSION);
 const f=await pdf.embedFont(fontBytes(MANROPE_REGULAR_B64),{subset:true}),b=await pdf.embedFont(fontBytes(MANROPE_BOLD_B64),{subset:true});
 const W=595.28,H=841.89,L=48,R=W-L,ink=rgb(.12,.17,.23),teal=rgb(.05,.40,.38),pale=rgb(.95,.97,.97),muted=rgb(.39,.45,.49),rule=rgb(.86,.89,.90);let page:PDFPage=pdf.addPage([W,H]),y=44;
 const text=(v:string,x:number,top:number,size=9,font=f,color=ink)=>{wrap(font,v,2000,size);if(x<0||x+font.widthOfTextAtSize(v,size)>W||top<0||top+size>H)throw Error('text_bounds');page.drawText(v,{x,y:H-top-size,size,font,color});};
 const right=(v:string,x:number,top:number,size=9,font=f,color=ink)=>text(v,x-font.widthOfTextAtSize(v,size),top,size,font,color);
 const rect=(x:number,top:number,w:number,h:number,color=pale)=>page.drawRectangle({x,y:H-top-h,width:w,height:h,color});
 const lines=(values:string[],x:number,top:number,width:number)=>{let at=top;for(const [i,value]of values.entries())for(const line of wrap(i===0?b:f,value,width,i===0?11:9)){text(line,x,at,i===0?11:9,i===0?b:f);at+=i===0?15:13;}return at;};
 const party=(p:BillingProfile)=>[p.legal_name,p.address_line||'',p.postal_code+' '+p.city,p.country_code==='CZ'?label('Česká republika','Czech Republic'):p.country_code,...(p.company_id?['IČO: '+p.company_id]:[]),...(p.tax_id?['DIČ: '+p.tax_id]:[])].filter(Boolean);
 if(brand){if(brand.view_box!==64||brand.paths.length>10||(brand.wordmark_paths?.length??0)>30)throw Error('brand_invalid');for(const shape of [...brand.paths,...(brand.wordmark_paths??[])]){if((shape.fill!=='none'&&!/^#[0-9a-fA-F]{6}$/.test(shape.fill))||(shape.stroke&&!/^#[0-9a-fA-F]{6}$/.test(shape.stroke))||shape.path.length>10000||(shape.stroke_width!==undefined&&(!Number.isFinite(shape.stroke_width)||shape.stroke_width<=0||shape.stroke_width>10)))throw Error('brand_invalid');const color=(hex:string)=>rgb(parseInt(hex.slice(1,3),16)/255,parseInt(hex.slice(3,5),16)/255,parseInt(hex.slice(5,7),16)/255);page.drawSvgPath(shape.path,{x:L,y:H-47,scale:32/brand.view_box,...(shape.fill!=='none'?{color:color(shape.fill)}:{}),...(shape.stroke?{borderColor:color(shape.stroke),borderWidth:shape.stroke_width??1}: {})});}if(!brand.wordmark_paths?.length)text(brand.name,L+42,55,13,b,teal);}else{rect(L,44,36,3,teal);text(s.brand_name,L,62,13,b,teal);}right(label('FAKTURA','INVOICE'),R,50,27,b);right(label('Číslo faktury: ','Invoice number: ')+s.number,R,91,10,b);
 if(s.simulation){rect(L,103,176,24,pale);text(label('SIMULACE - NEPLATIT','SIMULATION - DO NOT PAY'),L+10,111,8,b,teal);}else for(const [index,v] of wrap(f,s.command.period_start?`${s.command.period_start} - ${s.command.period_end_exclusive}`:s.command.source_ref,R-L,8).entries()){if(index>2)throw Error('document_too_large');text(v,L,110+index*12,8,f,muted);}
 rect(L,149,R-L,1,rule);text(label('DODAVATEL','SUPPLIER'),L,171,8,b,muted);text(label('ODBĚRATEL','CUSTOMER'),315,171,8,b,muted);y=Math.max(lines(party(s.issuer),L,192,230),lines(party(s.buyer),315,192,230))+24;
 if(y>420)throw Error('document_too_large');text(label('Vystaveno: ','Issued: ')+date(s.issued_on),L,y,9,f,muted);right(label('Splatnost: ','Due: ')+date(s.due_on),R,y,9,b);y+=30;
 rect(L,y,R-L,164);rect(L,y,3,164,teal);text(s.simulation?label('SIMULOVANÉ VYÚČTOVÁNÍ','SIMULATED STATEMENT'):label('CELKEM K ÚHRADĚ','TOTAL DUE'),L+18,y+17,8,b,muted);text(money(s.total_minor,english),L+18,y+36,27,b);
 const iban=validIban(s.account.iban),prefix=iban.slice(8,14).replace(/^0+/,''),account=iban.slice(14).replace(/^0+(?=\d)/,'');
 for(const [i,v]of [label('Účet: ','Account: ')+(prefix?prefix+'-':'')+account+'/'+iban.slice(4,8),'IBAN: '+iban,label('Variabilní symbol: ','Payment reference: ')+s.reference.normalized_vs,label('Splatnost: ','Due: ')+date(s.due_on)].entries())text(v,L+18,y+83+i*16,9);
 const qr=QR.create(spayd(s),{errorCorrectionLevel:'M'}),side=102.05,quiet=4,unit=side/(qr.modules.size+8),qx=R-side-20,qy=y+24;rect(qx,qy,side,side,rgb(1,1,1));if(unit<1.2)throw Error('qr_too_dense');for(let r=0;r<qr.modules.size;r++)for(let c=0;c<qr.modules.size;c++)if(qr.modules.get(r,c))rect(qx+(c+quiet)*unit,qy+(r+quiet)*unit,unit,unit,rgb(0,0,0));text(s.simulation?label('Neplatební QR','Non-payment QR'):label('QR platba','Payment QR'),qx,qy+112,8,b,muted);y+=186;
 const heading=()=>{rect(L,y,R-L,26,ink);text(label('POPIS POLOŽKY','DESCRIPTION'),L+10,y+8,8,b,rgb(1,1,1));right(label('POČET','QUANTITY'),348,y+8,8,b,rgb(1,1,1));right(label('CENA / KS','UNIT PRICE'),435,y+8,8,b,rgb(1,1,1));right(label('CELKEM','TOTAL'),R-10,y+8,8,b,rgb(1,1,1));y+=37;};
 const next=()=>{if(pdf.getPageCount()>=100)throw Error('document_too_large');page=pdf.addPage([W,H]);text(brand?.name??s.brand_name,L,44,15,b);right(s.number,R,48,10,b);y=90;heading();};if(y+65>746)next();else heading();
 let previous:string|null=null;
 for(const line of s.command.lines){
  const fragments=wrap(f,english?(line.description_en??line.description):line.description,250,9),group=line.group_label??null;
  if(y+Math.min(fragments.length*13+8,55)+(group!==previous&&group?30:0)>742)next();
  if(group&&group!==previous){for(const g of wrap(b,group,250,9)){if(y+30>742)next();text(g,L+8,y,9,b,teal);y+=14;}previous=group;}
  const sum=(BigInt(line.quantity)*BigInt(line.unit_minor)).toString();
  for(const [index,fragment]of fragments.entries()){if(y+20>742)next();text(fragment,L+8,y);if(index===0){const q=line.quantity,u=money(line.unit_minor,english),t=money(sum,english);if(f.widthOfTextAtSize(q,8)>44||f.widthOfTextAtSize(u,8)>82||b.widthOfTextAtSize(t,8)>100)throw Error('numeric_column_overflow');right(q,348,y,8);right(u,435,y,8);right(t,R-8,y,8,b);}y+=13;}rect(L,y+3,R-L,.5,rule);y+=14;
 }
 if(y+65>746)next();y+=16;text(label('Celkem v CZK','Total in CZK'),L+8,y,10,b);right(money(s.total_minor,english),R-8,y-5,21,b);text(label('Dodavatel není plátce DPH.','The supplier is not VAT registered.'),L+8,y+27,8,f,muted);
 for(let i=0;i<pdf.getPageCount();i++){page=pdf.getPage(i);rect(L,757,R-L,.5,rule);for(const [index,v] of wrap(f,s.issuer.email,R-L,8).entries()){if(index>2)throw Error('document_too_large');text(v,L,769+index*10,8,f,muted);}right(`${s.number} - ${label('strana','page')} ${i+1}/${pdf.getPageCount()}`,R,798,8);}
 return pdf.save();
}
