import test from 'node:test';
import assert from 'node:assert/strict';
import {scenario} from './email-delivery.fixture.mjs';
test('actual delivery path uses the application brand, Czech simulation text and no payment demand',async()=>{const {sent}=await scenario();assert.equal(sent.length,1);assert.equal(sent[0].FromEmailAddress,'CatalogPilot <issuer@example.invalid>');assert.match(sent[0].Content.Simple.Subject.Data,/CatalogPilot.*simulované.*říjen 2026/);assert.match(sent[0].Content.Simple.Body.Text.Data,/376,10 Kč/);assert.match(sent[0].Content.Simple.Body.Text.Data,/neplaťte/i);assert.ok(sent[0].Content.Simple.Body.Html);assert.doesNotMatch(sent[0].Content.Simple.Body.Text.Data,/VS:|Účet:/);});
test('feedback continues past provider validation messages and processes actual delivery events',async()=>{const {calls,deleted}=await scenario();assert.ok(calls.some(x=>x.p_op==='email_feedback'&&x.p_request.state==='delivered'));assert.ok(deleted.includes('delivery-handle'));assert.ok(calls.findIndex(x=>x.p_op==='email_feedback')<calls.findIndex(x=>x.p_op==='webhook_claim'));});

test('workerd runs branded email sending and consumes delivery feedback',async()=>{
 const {build}=await import('esbuild');const {Miniflare,convertV4MiniflareOptions}=await import('miniflare');
 const entry=`import {scenario} from './tests/email-delivery.fixture.mjs';export default {async fetch(){return Response.json(await scenario())}}`;
 const bundle=await build({stdin:{contents:entry,resolveDir:new URL('..',import.meta.url).pathname},bundle:true,write:false,platform:'browser',format:'esm',target:'es2022'});
 const runtime=new Miniflare(convertV4MiniflareOptions({name:'email-delivery-fixture',modules:true,script:bundle.outputFiles[0].text,compatibilityDate:'2026-10-01',cf:false}));
 try{const r=await runtime.dispatchFetch('https://fixture/test'),d=await r.json();assert.equal(r.status,200);assert.equal(d.sent[0].FromEmailAddress,'CatalogPilot <issuer@example.invalid>');assert.ok(d.calls.some(x=>x.p_op==='email_feedback'&&x.p_request.state==='delivered'));assert.ok(d.deleted.includes('delivery-handle'));}finally{await runtime.dispose();}
});

test('English customer receives English subject, body and amount',async()=>{
 const {invoiceEmail}=await import('../src/email.ts');const s={simulation:true,buyer:{language:'en'},brand_name:'fixture',number:'TEST-EN',total_minor:'12345',due_on:'2026-10-22',issuer:{email:'fixture@example.invalid'},command:{period_start:'2026-10-01'}};
 const email=invoiceEmail(s,{name:'CatalogPilot'},'InvoiceSync <fixture@example.invalid>',false,'fixture-pdf');assert.match(email.content.Simple.Subject.Data,/simulated statement for October 2026/);assert.match(email.content.Simple.Body.Text.Data,/123.45 CZK/);assert.match(email.content.Simple.Body.Text.Data,/do not pay/);assert.match(email.content.Simple.Body.Html.Data,/<html lang="en">/);
});
