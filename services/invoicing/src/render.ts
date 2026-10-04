// Adapted from the Mendelio/pdf-lib renderer; integer immutable snapshots only.
import {PDFDocument,rgb,type PDFFont,type PDFPage} from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';
import QR from 'qrcode/lib/core/qrcode.js';
import {DEJAVU_SANS_BOLD_B64,DEJAVU_SANS_REGULAR_B64} from './fonts.ts';
import type {InvoiceCommand,BillingProfile} from '../../../packages/invoicing-client/src/index.ts';
export const RENDERER_VERSION='invoicing-1';
export interface Snapshot {simulation:boolean;brand_name:string;number:string;issued_on:string;due_on:string;issuer:BillingProfile;buyer:BillingProfile;owner_email:string;account:{iban:string;physical_account_id:string};reference:{normalized_vs:string;reservation_id:string};command:InvoiceCommand;total_minor:string;tax_regime:'non_vat'}
export function validIban(value:string){const iban=value.replace(/\s/g,'').toUpperCase();if(!/^CZ\d{22}$/.test(iban))throw Error('iban_invalid');if(BigInt((iban.slice(4)+iban.slice(0,4)).replace(/[A-Z]/g,c=>String(c.charCodeAt(0)-55)))%97n!==1n)throw Error('iban_invalid');return iban;}
const amount=(v:string)=>{if(!/^\d{1,12}$/.test(v))throw Error('amount_invalid');const n=BigInt(v);return `${n/100n}.${String(n%100n).padStart(2,'0')}`;};
const money=(v:string)=>{const s=amount(v).split('.');return s[0].replace(/\B(?=(\d{3})+(?!\d))/g,' ')+','+s[1]+' Kč';};
export function spayd(s:Snapshot){if(s.simulation)return 'SIMULATION - NOT A PAYMENT';if(!/^\d{1,10}$/.test(s.reference.normalized_vs)||s.tax_regime!=='non_vat'||!/^\d{4}-\d{2}-\d{2}$/.test(s.due_on))throw Error('payment_snapshot_invalid');return `SPD*1.0*ACC:${validIban(s.account.iban)}*AM:${amount(s.total_minor)}*CC:CZK*X-VS:${s.reference.normalized_vs}*DT:${s.due_on.replaceAll('-','')}`;}
const fontBytes=(s:string)=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
function wrap(font:PDFFont,value:string,width:number,size:number){
 if(/[\u0000-\u0008\u000b-\u001f]/.test(value))throw Error('unsupported_character');const supported=new Set(font.getCharacterSet());for(const c of value)if(c!=='\n'&&!supported.has(c.codePointAt(0)!))throw Error('unsupported_character');
 const result:string[]=[];for(const paragraph of value.split('\n')){let current='';const graphemes=[...new Intl.Segmenter('cs',{granularity:'grapheme'}).segment(paragraph)].map(x=>x.segment);for(const c of graphemes){if(font.widthOfTextAtSize(current+c,size)>width){result.push(current.trimEnd());current=c.trimStart();}else current+=c;}result.push(current.trimEnd());}return result;
}
export async function renderInvoice(s:Snapshot):Promise<Uint8Array>{
 if(s.command.lines.length<1||s.command.lines.length>500)throw Error('document_too_large');const total=s.command.lines.reduce((sum,x)=>sum+BigInt(x.quantity)*BigInt(x.unit_minor),0n);if(total.toString()!==s.total_minor)throw Error('total_mismatch');
 const pdf=await PDFDocument.create();pdf.registerFontkit(fontkit);pdf.setCreationDate(new Date(s.issued_on+'T00:00:00Z'));pdf.setModificationDate(new Date(s.issued_on+'T00:00:00Z'));pdf.setTitle(s.number);pdf.setProducer(RENDERER_VERSION);pdf.setCreator(RENDERER_VERSION);
 const f=await pdf.embedFont(fontBytes(DEJAVU_SANS_REGULAR_B64),{subset:true}),b=await pdf.embedFont(fontBytes(DEJAVU_SANS_BOLD_B64),{subset:true});
 const W=595.28,H=841.89,L=48,R=W-L,ink=rgb(.09,.17,.20),teal=rgb(.06,.46,.43),pale=rgb(.94,.97,.96);let page:PDFPage=pdf.addPage([W,H]),y=44;
 const text=(v:string,x:number,top:number,size=9,font=f)=>{wrap(font,v,2000,size);if(x<0||x+font.widthOfTextAtSize(v,size)>W||top<0||top+size>H)throw Error('text_bounds');page.drawText(v,{x,y:H-top-size,size,font,color:ink});};
 const right=(v:string,x:number,top:number,size=9,font=f)=>text(v,x-font.widthOfTextAtSize(v,size),top,size,font);
 const rect=(x:number,top:number,w:number,h:number,color=pale)=>page.drawRectangle({x,y:H-top-h,width:w,height:h,color});
 const lines=(values:string[],x:number,top:number,width:number)=>{let at=top;for(const [i,value]of values.entries())for(const line of wrap(i===0?b:f,value,width,i===0?11:9)){text(line,x,at,i===0?11:9,i===0?b:f);at+=i===0?15:13;}return at;};
 const party=(p:BillingProfile)=>[p.legal_name,p.address_line||'',p.postal_code+' '+p.city,p.country_code==='CZ'?'Česká republika':p.country_code,...(p.company_id?['IČO: '+p.company_id]:[]),...(p.tax_id?['DIČ: '+p.tax_id]:[])].filter(Boolean);
 text(s.brand_name,L,y,19,b);right('FAKTURA',R,y,24,b);right(s.number,R,78,11,b);if(s.simulation)text('SIMULACE - NEPLATIT',L,104,11,b);else for(const [index,v] of wrap(f,s.command.period_start?`${s.command.period_start} - ${s.command.period_end_exclusive}`:s.command.source_ref,R-L,9).entries()){if(index>2)throw Error('document_too_large');text(v,L,104+index*12,9);}
 text('DODAVATEL',L,144,8,b);text('ODBĚRATEL',315,144,8,b);y=Math.max(lines(party(s.issuer),L,162,230),lines(party(s.buyer),315,162,230))+16;
 if(y>420)throw Error('document_too_large');text('Vystaveno: '+s.issued_on,L,y);right('Splatnost: '+s.due_on,R,y,9,b);y+=30;
 rect(L,y,R-L,145);text(s.simulation?'SIMULOVANÉ VYÚČTOVÁNÍ':'CELKEM K ÚHRADĚ PŘI VYSTAVENÍ',L+15,y+12,8,b);text(money(s.total_minor),L+15,y+30,25,b);
 if(!s.simulation){for(const [i,v]of ['Účet: '+s.account.iban,'Variabilní symbol: '+s.reference.normalized_vs,'Splatnost: '+s.due_on].entries())text(v,L+15,y+75+i*17,9);}
 const qr=QR.create(spayd(s),{errorCorrectionLevel:'M'}),side=102.05,quiet=4,unit=side/(qr.modules.size+8),qx=R-side-13,qy=y+12;rect(qx,qy,side,side,rgb(1,1,1));if(unit<1.2)throw Error('qr_too_dense');for(let r=0;r<qr.modules.size;r++)for(let c=0;c<qr.modules.size;c++)if(qr.modules.get(r,c))rect(qx+(c+quiet)*unit,qy+(r+quiet)*unit,unit,unit,rgb(0,0,0));text(s.simulation?'Neplatební QR':'QR platba',qx,qy+107,8,b);y+=168;
 const heading=()=>{rect(L,y,R-L,24);text('SLUŽBA / E-SHOP',L+8,y+7,8,b);right('POČET',348,y+7,8,b);right('CENA / KS',435,y+7,8,b);right('CELKEM',R-8,y+7,8,b);y+=30;};
 const next=()=>{if(pdf.getPageCount()>=100)throw Error('document_too_large');page=pdf.addPage([W,H]);text(s.brand_name,L,44,15,b);right(s.number,R,48,10,b);y=90;heading();};if(y+65>746)next();else heading();
 let previous:string|null=null;
 for(const line of s.command.lines){
  const fragments=wrap(f,line.description,250,9),group=line.group_label??null;
  if(y+Math.min(fragments.length*13+8,55)+(group!==previous&&group?30:0)>742)next();
  if(group&&group!==previous){for(const g of wrap(b,group,250,9)){if(y+30>742)next();text(g,L+8,y,9,b);y+=14;}previous=group;}
  const sum=(BigInt(line.quantity)*BigInt(line.unit_minor)).toString();
  for(const [index,fragment]of fragments.entries()){if(y+20>742)next();text(fragment,L+8,y);if(index===0){const q=line.quantity,u=money(line.unit_minor),t=money(sum);if(f.widthOfTextAtSize(q,8)>44||f.widthOfTextAtSize(u,8)>82||b.widthOfTextAtSize(t,8)>100)throw Error('numeric_column_overflow');right(q,348,y,8);right(u,435,y,8);right(t,R-8,y,8,b);}y+=13;}y+=9;
 }
 if(y+65>746)next();y+=12;text('Celkem',L+8,y,11,b);right(money(s.total_minor),R-8,y-3,17,b);text('Dodavatel není plátce DPH.',L+8,y+29,8);
 for(let i=0;i<pdf.getPageCount();i++){page=pdf.getPage(i);for(const [index,v] of wrap(f,s.issuer.email,R-L,8).entries()){if(index>2)throw Error('document_too_large');text(v,L,756+index*11,8);}right(`${s.number} - strana ${i+1}/${pdf.getPageCount()}`,R,798,8);}
 return pdf.save();
}
