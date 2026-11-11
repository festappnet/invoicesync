import test from 'node:test';
import assert from 'node:assert/strict';
import {buildWebhookEnvelope, signWebhook} from '@festapp/banksync';
import {createService} from '../src/worker.ts';
import {build} from 'esbuild';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';

test('pinned BankSync SDK preserves signed v2 facts, receipts and rejection before RPC', async () => {
  const transaction = {
    id: 1, bank_account_id: 42, amount_cents: 1007, currency: 'CZK',
    counter_account: null, bank_code: null, bank_name: null, vs: '12345',
    ks: null, ss: null, message: null, sender_name: null,
    user_identification: null, transaction_type: null, performed_by: null,
    comment: null, command_id: null, source: 'fio_api',
    date: '2026-10-24T12:00:00Z', date_offset_min: 0,
    transaction_id: 'fixture-movement', external_id: null,
    payer_reference: null, raw_vs: '12345', direction: 'incoming',
    identity_kind: 'movement', identity_provenance: 'fio_api_column22',
  };
  const envelope = buildWebhookEnvelope({
    delivery_id: '01K00000000000000000000001', pairing_code: '0123456789',
    transaction, event_version: '2',
  });
  const secret = 'synthetic-bank-secret';
  const workload = {
    app_id: 'fixture', token: 'fixture-workload', bank_account_id: 42,
    pairing_code: envelope.pairing_code, bank_secrets: [secret],
    instance_id: 'fixture-instance', consumer_id: 'fixture',
  };
  const env = {ENVIRONMENT: 'simulation', RPC_ORIGIN: 'https://rpc.example.invalid',
    WORKLOADS_JSON: JSON.stringify([workload])};
  const calls = [];
  const receipt = {ok: true, receipt_version: 1, delivery_id: envelope.delivery_id};
  const service = createService(async (input, options) => {
    const request = new Request(input, options);
    assert.equal(request.headers.get('Authorization'), 'Bearer fixture-workload');
    calls.push(await request.json());
    return Response.json(receipt);
  });
  async function send(value = envelope, tamper = false) {
    const signed = await signWebhook({envelope: value, secret});
    const headers = new Headers(signed.headers);
    if (tamper) headers.set('X-BankSync-Signature', 'sha256=' + '0'.repeat(64));
    return service.fetch(new Request('https://fixture.example/webhooks/banksync', {
      method: 'POST', headers, body: signed.bodyBytes,
    }), env);
  }
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await send();
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), receipt);
  }
  assert.equal(calls[0].p_op, 'bank_receive');
  assert.equal(calls[0].p_request.envelope.data.amount_cents, 1007);
  assert.equal(calls[0].p_request.envelope.data.raw_vs, '12345');
  assert.equal(calls[0].p_request.envelope.data.reference_conflict, false);
  assert.equal(calls[0].p_request.payload_hash, calls[1].p_request.payload_hash);
  assert.equal((await send(envelope, true)).status, 403);
  assert.equal((await send({...envelope, data: {...envelope.data, bank_account_id: 43}})).status, 403);
  assert.equal(calls.length, 2);
  for(const status of [401,403]){
    const rejected=createService(async()=>Response.json({code:status===401?'PGRST303':'42501',message:status===401?'JWT expired':'workload_revoked'},{status}));
    const signed=await signWebhook({envelope,secret});
    const response=await rejected.fetch(new Request('https://fixture.example/webhooks/banksync',{method:'POST',headers:signed.headers,body:signed.bodyBytes}),env);
    assert.equal(response.status,503,'internal credential rejection must remain retryable after sender authentication');
    assert.deepEqual(await response.json(),{error:'bank_receiver_unavailable'});
  }
});

test('workerd keeps authenticated bank deliveries retryable when its database identity expires',async()=>{
  const secret='isolated-workerd-bank-secret';
  const envelope=buildWebhookEnvelope({delivery_id:'01K00000000000000000000002',pairing_code:'0123456789',event_version:'2',transaction:{
    id:1,bank_account_id:42,amount_cents:-19700,currency:'CZK',direction:'outgoing',source:'fio_api',
    date:'2026-11-09T12:00:00Z',date_offset_min:0,identity_kind:'movement',identity_provenance:'fio_api_column22',transaction_id:'isolated-fixture-movement',
    counter_account:null,bank_code:null,bank_name:null,vs:null,ks:null,ss:null,message:null,sender_name:null,
    user_identification:null,transaction_type:null,performed_by:null,comment:null,command_id:null,external_id:null,payer_reference:null,raw_vs:null,
  }});
  const bundle=await build({stdin:{contents:`import {createService} from './src/worker.ts';export default {fetch(request,env){return createService(async()=>Response.json({code:'PGRST303',message:'JWT expired'},{status:Number(env.FIXTURE_STATUS)})).fetch(request,env)}}`,resolveDir:process.cwd(),sourcefile:'bank-identity-fixture.ts'},bundle:true,write:false,platform:'browser',format:'esm',target:'es2022'});
  for(const status of [401,403]){
    const runtime=new Miniflare(convertV4MiniflareOptions({name:'isolated-bank-identity',modules:true,script:bundle.outputFiles[0].text,compatibilityDate:'2026-10-01',cf:false,bindings:{ENVIRONMENT:'simulation',RPC_ORIGIN:'https://rpc.example.invalid',FIXTURE_STATUS:String(status),WORKLOADS_JSON:JSON.stringify([{app_id:'fixture',token:'fixture-internal-token',bank_account_id:42,pairing_code:envelope.pairing_code,bank_secrets:[secret],instance_id:'isolated-instance',consumer_id:'fixture'}])}}));
    try{
      const signed=await signWebhook({envelope,secret});
      const response=await runtime.dispatchFetch('https://fixture.example/webhooks/banksync',{method:'POST',headers:signed.headers,body:signed.bodyBytes});
      assert.equal(response.status,503);
      assert.deepEqual(await response.json(),{error:'bank_receiver_unavailable'});
      const headers=new Headers(signed.headers);headers.set('X-BankSync-Signature','sha256='+'0'.repeat(64));
      const rejected=await runtime.dispatchFetch('https://fixture.example/webhooks/banksync',{method:'POST',headers,body:signed.bodyBytes});
      assert.equal(rejected.status,403,'invalid sender remains a permanent rejection');
    }finally{await runtime.dispose();}
  }
});
