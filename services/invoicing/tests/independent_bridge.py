"""A second consumer over real PostgreSQL, without CatalogPilot RPC integration."""
import sys,json,traceback
import psycopg
from test_authority import AuthorityTests
case=AuthorityTests('test_01_concurrent_idempotence_and_second_consumer')
try:
 AuthorityTests.setUpClass()
 with psycopg.connect(case.owner_dsn) as c:
  c.execute("UPDATE invoicing.receiving_accounts SET reference_mode='service' WHERE app_id='second-consumer'")
  c.execute("UPDATE invoicing.applications SET callback_url='https://second-fixture.example/callback',callback_key_id='current' WHERE id='second-consumer'")
 print(json.dumps({'ready':True}),flush=True)
 for line in sys.stdin:
  try:
   request=json.loads(line)
   if request['op']=='close':print(json.dumps({'value':True}),flush=True);break
   if request['op']=='fixture_banksync':
    with psycopg.connect(case.owner_dsn) as c:c.execute("UPDATE invoicing.receiving_accounts SET reference_mode='banksync' WHERE app_id='second-consumer'")
    result={'ok':True}
   else:result=case.call(request['op'],request.get('request',{}),app='second-consumer')
   print(json.dumps({'value':result}),flush=True)
  except Exception as e:print(json.dumps({'error':str(e),'code':getattr(e,'sqlstate',None)}),flush=True)
except Exception:traceback.print_exc(file=sys.stderr)
finally:
 if hasattr(AuthorityTests,'tmp'):AuthorityTests.tearDownClass()
