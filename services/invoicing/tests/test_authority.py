"""Real isolated PostgreSQL, labelled external fixtures; no external effects."""
import json
import unittest
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import psycopg
from psycopg.types.json import Jsonb
from postgres_case import PostgresCase
SERVICE=Path(__file__).resolve().parents[1]
PROFILE={'party_type':'company','legal_name':'Fiktivní subjekt','company_id':'00000001','tax_id':None,'address_line':'Vzorová 12/3a','city':'Brno','postal_code':'60200','country_code':'CZ','email':'fixture@example.invalid'}
COMMAND={'customer_id':'fixture','issuer_profile_id':'issuer','source_ref':'test:one','kind':'one_off','currency':'CZK','lines':[{'source_line_id':'x','description':'Testovací služba','quantity':'2','unit_minor':'100'}],'delivery_policy':'automatic_customer_copy_owner'}
class AuthorityTests(PostgresCase):
 @classmethod
 def setUpClass(cls):
  super().setUpClass()
  with psycopg.connect(cls.owner_dsn) as c:
   for p in sorted((SERVICE/'migrations').glob('*.sql')):c.execute(p.read_text())
   for app in ['app-a','second-consumer']:
    c.execute("INSERT INTO invoicing.applications(id,environment) VALUES(%s,'simulation')",(app,))
    c.execute("INSERT INTO invoicing.credentials(jti_hash,app_id,scopes,expires_at) VALUES(encode(sha256(convert_to(%s,'UTF8')),'hex'),%s,ARRAY['read','write','bank','deliver','jobs'],now()+interval '1 hour')",(app,app))
    c.execute("INSERT INTO invoicing.customers VALUES(%s,'fixture',%s,1,0,NULL)",(app,Jsonb(PROFILE)))
    c.execute("INSERT INTO invoicing.receiving_accounts(app_id,id,iban,physical_account_id,bank_account_id,instance_id,consumer_id,activation_at,verified,reference_mode) VALUES(%s,'account','CZ6508000000192000145399',%s,1,'fixture-instance',%s,'2020-01-01',true,'banksync')",(app,app+'-physical',app))
    c.execute("INSERT INTO invoicing.issuer_profiles VALUES(%s,'issuer',%s,'account',true,'non_vat',14,'owner@example.invalid','TEST')",(app,Jsonb(PROFILE)))
 def call(self,op,p=None,app='app-a',claims=None):
  with psycopg.connect(self.owner_dsn) as c:
   c.execute('SET LOCAL ROLE invoicing_gateway')
   c.execute("SELECT set_config('request.jwt.claims',%s,true)",(json.dumps(claims or {'role':'invoicing_gateway','aud':'invoicing-rpc','jti':app,'exp':4102444800}),))
   return c.execute('SELECT invoicing_api.dispatch(%s,%s)',(op,Jsonb(p or {}))).fetchone()[0]
 def create(self,source='test:one',app='app-a'):
  return self.call('invoice_create',{'command':{**COMMAND,'source_ref':source},'key':source},app)['invoice_id']
 def issue(self,id,vs='12345',app='app-a'):
  return self.call('issue',{'invoice_id':id,'reference':{'reservation_id':id,'physical_account_id':app+'-physical','source_ref':next(x['source_ref'] for x in self.call('issue_list',app=app) if x['invoice_id']==id),'normalized_vs':vs,'app_id':app,'payload_hash':next(x['payload_hash'] for x in self.call('issue_list',app=app) if x['invoice_id']==id)}},app)
 def test_01_concurrent_idempotence_and_second_consumer(self):
  with ThreadPoolExecutor(4) as pool:ids=list(pool.map(lambda _:self.create(),range(8)))
  self.assertEqual(len(set(ids)),1)
  with self.assertRaises(psycopg.errors.UniqueViolation):self.call('invoice_create',{'command':{**COMMAND,'lines':[{'source_line_id':'x','description':'Changed','quantity':'1','unit_minor':'999'}]},'key':'test:one'})
  second=self.create(app='second-consumer');self.assertNotEqual(second,ids[0])
  with self.assertRaises(psycopg.errors.NoDataFound):self.call('invoice_get',{'invoice_id':second})
  with self.assertRaises(psycopg.errors.InsufficientPrivilege):self.call('invoice_get',{'invoice_id':ids[0]},claims={'role':'invoicing_gateway','aud':'wrong','jti':'app-a','exp':4102444800})
 def test_02_immutable_invoice_and_payment_before_pdf(self):
  id=self.create('test:payment');self.issue(id)
  d={'bank_account_id':1,'amount_cents':50,'currency':'CZK','vs':'12345','raw_vs':'12345','identity_kind':'movement','transaction_id':'movement-1','source':'fio_api','date':'2026-10-04T12:00:00Z'}
  def receive(delivery,movement='movement-1',amount=50):return self.call('bank_receive',{'instance_id':'fixture-instance','consumer_id':'app-a','payload_hash':delivery.ljust(64,'0'),'envelope':{'delivery_id':delivery,'data':{**d,'transaction_id':movement,'amount_cents':amount}}})
  self.assertEqual(receive('delivery-1')['outcome'],'allocated');receive('delivery-1');receive('delivery-2');self.assertEqual(self.call('invoice_get',{'invoice_id':id})['allocated_minor'],'50')
  receive('delivery-3','movement-2',200);invoice=self.call('invoice_get',{'invoice_id':id});self.assertEqual(invoice['allocated_minor'],'200');self.assertEqual(invoice['payment_state'],'paid');self.assertEqual(invoice['artifact_state'],'pending')
  with psycopg.connect(self.owner_dsn) as c:
   with self.assertRaises(psycopg.errors.RaiseException):c.execute("UPDATE invoicing.invoices SET total_minor=201 WHERE id=%s",(id,))
 def test_03_observation_and_unauthorized_table_write(self):
  id=self.create('test:observation');self.issue(id,'67890')
  self.call('bank_receive',{'instance_id':'fixture-instance','consumer_id':'app-a','payload_hash':'a'*64,'envelope':{'delivery_id':'obs','data':{'bank_account_id':1,'amount_cents':200,'currency':'CZK','vs':'67890','raw_vs':'67890','identity_kind':'observation','transaction_id':None,'source':'email','date':'2026-10-04T12:00:00Z'}}})
  self.assertEqual(self.call('invoice_get',{'invoice_id':id})['allocated_minor'],'0')
  with psycopg.connect(self.owner_dsn) as c:
   c.execute('SET LOCAL ROLE invoicing_gateway')
   with self.assertRaises(psycopg.errors.InsufficientPrivilege):c.execute("UPDATE invoicing.invoices SET allocated_minor=200")
 def test_05_optional_service_and_provided_references(self):
  with psycopg.connect(self.owner_dsn) as c:c.execute("UPDATE invoicing.receiving_accounts SET reference_mode='service' WHERE app_id='second-consumer'")
  id=self.create('test:local',app='second-consumer');reference=self.call('service_reference',{'invoice_id':id},'second-consumer')
  self.assertEqual(self.call('service_reference',{'invoice_id':id},'second-consumer'),reference)
  self.assertTrue(reference['reservation_id'].startswith('service:'))
  self.call('issue',{'invoice_id':id,'reference':reference},'second-consumer')
  with psycopg.connect(self.owner_dsn) as c:c.execute("UPDATE invoicing.receiving_accounts SET reference_mode='provided' WHERE app_id='second-consumer'")
  command={**COMMAND,'source_ref':'provided:one','variable_symbol':'00044444'}
  created=self.call('invoice_create',{'command':command,'key':'provided:one'},'second-consumer')['invoice_id']
  h=next(x['payload_hash'] for x in self.call('issue_list',app='second-consumer') if x['invoice_id']==created)
  r={'reservation_id':'provided:'+created,'physical_account_id':'second-consumer-physical','source_ref':'simulation:'+created,'normalized_vs':'00044444','app_id':'second-consumer','payload_hash':h}
  self.call('issue',{'invoice_id':created,'reference':r},'second-consumer')
  with self.assertRaises(psycopg.errors.InvalidParameterValue):self.create('provided:missing',app='second-consumer')
 def test_04_profile_version_and_expired_credential(self):
  saved=self.call('profile_save',{'customer_id':'fixture','version':1,'profile':{**PROFILE,'legal_name':'Nový návrh'}});self.assertEqual(saved['version'],2)
  with self.assertRaises(psycopg.errors.SerializationFailure):self.call('profile_save',{'customer_id':'fixture','version':1,'profile':PROFILE})
  with self.assertRaises(psycopg.errors.InsufficientPrivilege):self.call('profile_get',{'customer_id':'fixture'},claims={'role':'invoicing_gateway','aud':'invoicing-rpc','jti':'app-a','exp':1})

 def test_06_overdue_once_and_email_unknown_fence(self):
  id=self.create('test:delivery')
  with psycopg.connect(self.owner_dsn) as c:c.execute("UPDATE invoicing.applications SET environment='live' WHERE id='app-a'")
  self.issue(id,'88888')
  self.call('artifact_ready',{'invoice_id':id,'object_key':'fixture/private.pdf','sha256':'a'*64,'renderer_version':'fixture','bytes':100})
  with psycopg.connect(self.owner_dsn) as c:c.execute("UPDATE invoicing.applications SET environment='simulation' WHERE id='app-a'")
  row=self.call('email_claim',{'worker':'worker-a'});self.assertIsNotNone(row)
  begin={'id':row['id'],'worker':'worker-a','fence':row['fence']};self.call('email_begin',begin)
  with psycopg.connect(self.owner_dsn) as c:
   c.execute("UPDATE invoicing.delivery_outbox SET lease_until=now()-interval '1 second' WHERE id=%s",(row['id'],))
   c.execute('ALTER TABLE invoicing.invoices DISABLE TRIGGER invoice_freeze')
   c.execute("UPDATE invoicing.invoices SET due_on=current_date-1 WHERE id=%s",(id,))
   c.execute('ALTER TABLE invoicing.invoices ENABLE TRIGGER invoice_freeze')
  self.call('email_claim',{'worker':'worker-b'})
  with self.assertRaises(psycopg.errors.RaiseException):self.call('email_accepted',{**begin,'provider_id':'stale'})
  self.assertIn('unknown',[d['state'] for d in self.call('invoice_get',{'invoice_id':id})['deliveries']])
  feedback={'id':row['id'],'event_id':'fixture-delivered','provider_id':'fixture-ses-message','recipient':row['recipient'],'state':'delivered'}
  self.call('email_feedback',feedback);self.call('email_feedback',feedback)
  self.call('email_feedback',{**feedback,'event_id':'fixture-bounce','state':'bounced'})
  delivery=self.call('invoice_get',{'invoice_id':id})['deliveries'];self.assertEqual(sum(d['state']=='bounced' for d in delivery),1);self.assertEqual(len(delivery),2)
  self.call('overdue_sweep');self.call('overdue_sweep')
  events=self.call('events')['events'];self.assertEqual(sum(e['event_type']=='invoice.overdue' and e['data']['invoice_id']==id for e in events),1)
 def test_07_scheduler_month_end_idempotency_and_revision(self):
  plan={**COMMAND,'source_ref':'schedule-plan'}
  command={'customer_id':'fixture','issuer_profile_id':'issuer','plan':plan,'interval':'month','interval_count':1,'anchor_on':'2024-01-31','starts_on':'2024-01-31','ends_before':'2024-03-01','timezone':'Europe/Prague','pause_policy':'defer','key':'fixture-schedule'}
  schedule=self.call('schedule_create',command);self.assertEqual(self.call('schedule_create',command)['id'],schedule['id'])
  self.call('schedule_sweep');self.call('schedule_sweep');self.call('schedule_sweep')
  with psycopg.connect(self.owner_dsn) as c:
   dates=[str(r[0]) for r in c.execute("SELECT occurrence FROM invoicing.schedule_occurrences WHERE schedule_id=%s ORDER BY occurrence",(schedule['id'],)).fetchall()]
  self.assertEqual(dates,['2024-01-31','2024-02-29'])
  changed=self.call('schedule_update',{'schedule_id':schedule['id'],'version':1,'change':{'status':'cancelled'}});self.assertEqual(changed['revision'],2)
  with self.assertRaises(psycopg.errors.SerializationFailure):self.call('schedule_update',{'schedule_id':schedule['id'],'version':1,'change':{'status':'active'}})

 def test_08_all_customer_debts_and_wrong_currency(self):
  with psycopg.connect(self.owner_dsn) as c:c.execute("INSERT INTO invoicing.customers VALUES('app-a','two-debts',%s,1,0,NULL)",(Jsonb(PROFILE),))
  ids=[]
  for index in range(2):
   source='debt:'+str(index);id=self.call('invoice_create',{'command':{**COMMAND,'customer_id':'two-debts','source_ref':source},'key':source})['invoice_id'];self.issue(id,str(90001+index));ids.append(id)
  with psycopg.connect(self.owner_dsn) as c:
   c.execute('ALTER TABLE invoicing.invoices DISABLE TRIGGER invoice_freeze');c.execute("UPDATE invoicing.invoices SET due_on=current_date-1 WHERE customer_id='two-debts'");c.execute('ALTER TABLE invoicing.invoices ENABLE TRIGGER invoice_freeze')
  self.assertEqual(self.call('customer_status',{'customer_id':'two-debts'})['overdue_total_minor'],'400')
  def pay(index,currency='CZK'):
   delivery='debt-payment:'+str(index)+currency
   return self.call('bank_receive',{'instance_id':'fixture-instance','consumer_id':'app-a','payload_hash':('c' if currency=='CZK' else 'd')*64,'envelope':{'delivery_id':delivery,'data':{'bank_account_id':1,'amount_cents':200,'currency':currency,'vs':str(90001+index),'raw_vs':str(90001+index),'identity_kind':'movement','transaction_id':delivery,'source':'fio_api','date':'2026-10-04T12:00:00Z'}}})
  self.assertEqual(pay(0,'EUR')['outcome'],'reconciliation_required');self.assertEqual(self.call('invoice_get',{'invoice_id':ids[0]})['allocated_minor'],'0')
  pay(0);self.assertEqual(self.call('customer_status',{'customer_id':'two-debts'})['overdue_total_minor'],'200')
  pay(1);self.assertEqual(self.call('customer_status',{'customer_id':'two-debts'})['overdue_total_minor'],'0')


 def test_09_customer_language_is_validated_persisted_and_frozen(self):
  profile=self.call('profile_get',{'customer_id':'fixture'})
  with self.assertRaises(psycopg.errors.InvalidParameterValue):
   self.call('profile_save',{'customer_id':'fixture','version':profile['version'],'profile':{**PROFILE,'language':'de'}})
  saved=self.call('profile_save',{'customer_id':'fixture','version':profile['version'],'profile':{**PROFILE,'language':'en'}})
  self.assertEqual(saved['profile']['language'],'en')
  invoice=self.create('test:english');self.issue(invoice,vs='778899')
  read=self.call('invoice_get',{'invoice_id':invoice})
  self.assertEqual(read['snapshot']['buyer']['language'],'en')
  self.assertTrue(read['simulation'])

def load_tests(loader,tests,pattern):return unittest.TestSuite(AuthorityTests(name) for name in AuthorityTests.__dict__ if name.startswith('test_'))
