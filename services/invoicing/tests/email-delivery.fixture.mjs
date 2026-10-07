import {drain} from '../src/worker.ts';
const bytes=new TextEncoder().encode('%PDF-fixture');
const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('');
const snapshot={simulation:true,brand_name:'catalogpilot',number:'TEST-2026-000001',total_minor:'37610',due_on:'2026-10-22',buyer:{language:'cs'},issuer:{email:'issuer@example.invalid'},account:{iban:'CZ6508000000192000145399'},reference:{normalized_vs:'12345'},command:{period_start:'2026-10-01',period_end_exclusive:'2026-11-01'}};
export async function scenario(run=drain){
 const calls=[],sent=[],deleted=[];let claimed=false,received=0;
 const w={app_id:'fixture',token:'fixture',banksync_origin:'https://bank.fixture',bank_account_id:1,email_from:'InvoiceSync <issuer@example.invalid>',email_configuration_set:'fixture-only',feedback_queue_url:'https://sqs.eu-central-1.amazonaws.com/fixture/queue',webhook_keys:{}};
 const env={ENVIRONMENT:'live',LIVE_ACTIVATION:'verified-configuration',RPC_ORIGIN:'https://rpc.fixture',AWS_REGION:'eu-central-1',AWS_ACCESS_KEY_ID:'fixture-key',AWS_SECRET_ACCESS_KEY:'fixture-secret',BRANDS_JSON:JSON.stringify({fixture:{name:'CatalogPilot',view_box:64,paths:[]}}),INVOICE_ARTIFACTS:{get:async()=>({arrayBuffer:async()=>bytes.buffer})}};
 const transport=async(input,options)=>{const r=new Request(input,options),url=new URL(r.url),p=await r.json();
 if(url.hostname==='rpc.fixture'){calls.push(p);switch(p.p_op){case 'issue_list':case 'render_list':return Response.json([]);case 'webhook_claim':return Response.json(null);case 'email_claim':if(claimed)return Response.json(null);claimed=true;return Response.json({id:'delivery',fence:1,recipient:'customer@example.invalid',recipient_role:'customer',artifact_hash:hash,artifact:{object_key:'fixture',sha256:hash},snapshot});default:return Response.json({});}}
 if(url.hostname==='bank.fixture')return Response.json({bank_observation_status:'healthy'});
 if(url.hostname==='email.eu-central-1.amazonaws.com'){sent.push(p);return Response.json({MessageId:'fixture-provider-id'});}
 if(url.hostname==='sqs.eu-central-1.amazonaws.com'){const action=r.headers.get('x-amz-target');if(action.endsWith('DeleteMessage')){deleted.push(p.ReceiptHandle);return Response.json({});}if(action.endsWith('ReceiveMessage')){received++;if(received===1)return Response.json({Messages:[{MessageId:'validation',ReceiptHandle:'validation-handle',Body:'Successfully validated SNS topic for Amazon SES event publishing.'}]});if(received===2)return Response.json({Messages:[{MessageId:'feedback',ReceiptHandle:'delivery-handle',Body:JSON.stringify({eventType:'Delivery',mail:{messageId:'fixture-provider-id',destination:['customer@example.invalid'],tags:{invoicing_app:['fixture'],invoicing_delivery_id:['delivery']}}})}]});return Response.json({Messages:[]});}}
 throw Error('unexpected_fixture_request:'+url.hostname);
 };
 await run(env,w,transport);return {calls,sent,deleted};
}
