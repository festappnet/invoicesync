#!/usr/bin/env python3
"""Generate reviewable SQL from a frozen BankSync D1 reference export. No DB writes."""
import argparse, hashlib, json, re
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--snapshot',type=Path,required=True)
p.add_argument('--expected-sha256',required=True)
p.add_argument('--physical-account-id',required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--history-reviewed',action='store_true',required=True)
a=p.parse_args()
data=a.snapshot.read_bytes(); digest=hashlib.sha256(data).hexdigest()
if digest!=a.expected_sha256:raise SystemExit('Snapshot digest mismatch')
if not re.fullmatch(r'[a-zA-Z0-9:_-]{1,160}',a.physical_account_id):raise SystemExit('Invalid physical identity')
if a.output.exists():raise SystemExit('Refusing to overwrite adoption SQL')
raw=json.loads(data);rows=raw[0]['results']
rows=[r for r in rows if r['physical_account_id']==a.physical_account_id]
if not rows:raise SystemExit('No history for the selected account')
seen=set()
for r in rows:
 if not re.fullmatch(r'\d{1,10}',r['normalized_vs']):raise SystemExit('Invalid historical reference')
 r['normalized_vs']=str(int(r['normalized_vs']))
 if r['normalized_vs'] in seen:raise SystemExit('Duplicate normalized historical reference')
 seen.add(r['normalized_vs'])
def lit(v):return "'"+str(v).replace("'","''")+"'"
physical=lit(a.physical_account_id)
sql=f'''BEGIN;
LOCK TABLE invoicing.receiving_accounts IN SHARE MODE;
SELECT 1 FROM invoicing.reference_namespaces WHERE physical_account_id={physical} FOR UPDATE;
CREATE TEMP TABLE adopted_bank_references(reservation_id text,physical_account_id text,app_id text,source_ref text,normalized_vs text,payload_hash text) ON COMMIT DROP;
INSERT INTO adopted_bank_references VALUES
'''+',\n'.join('('+','.join(lit(r[k]) for k in ['reservation_id','physical_account_id','app_id','source_ref','normalized_vs','payload_hash'])+')' for r in rows)+''';
INSERT INTO invoicing.reference_exclusions SELECT physical_account_id,normalized_vs,source_ref,payload_hash FROM adopted_bank_references ON CONFLICT DO NOTHING;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM adopted_bank_references b JOIN invoicing.reference_exclusions x USING(physical_account_id,normalized_vs) WHERE (b.source_ref,b.payload_hash) IS DISTINCT FROM(x.source_ref,x.payload_hash)) THEN RAISE EXCEPTION 'exclusion_history_mismatch';END IF;
END $$;
-- Recover a committed remote reservation for an existing pending/issued invoice
-- only when every original consumer/source/hash/account identity agrees.
INSERT INTO invoicing.payment_reference_claims(app_id,invoice_id,physical_account_id,normalized_vs,mode,reservation_id)
 SELECT i.app_id,i.id,b.physical_account_id,b.normalized_vs,'banksync',b.reservation_id
 FROM adopted_bank_references b JOIN invoicing.receiving_accounts r ON r.physical_account_id=b.physical_account_id AND r.consumer_id=b.app_id
 JOIN invoicing.issuer_profiles s ON(s.app_id,s.account_id)=(r.app_id,r.id)
 JOIN invoicing.invoices i ON(i.app_id,i.issuer_id)=(s.app_id,s.id)
 JOIN invoicing.applications app ON app.id=i.app_id
 WHERE b.source_ref=app.environment||':'||i.id::text AND b.payload_hash=i.payload_hash
 ON CONFLICT DO NOTHING;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM adopted_bank_references b JOIN invoicing.receiving_accounts r ON r.physical_account_id=b.physical_account_id AND r.consumer_id=b.app_id
 JOIN invoicing.issuer_profiles s ON(s.app_id,s.account_id)=(r.app_id,r.id)
 JOIN invoicing.invoices i ON(i.app_id,i.issuer_id)=(s.app_id,s.id)
 JOIN invoicing.applications app ON app.id=i.app_id
 WHERE b.source_ref=app.environment||':'||i.id::text AND (b.payload_hash<>i.payload_hash OR NOT EXISTS(
 SELECT 1 FROM invoicing.payment_reference_claims c WHERE c.app_id=i.app_id AND c.invoice_id=i.id AND c.reservation_id=b.reservation_id AND c.normalized_vs=b.normalized_vs))) THEN RAISE EXCEPTION 'invoice_reference_history_mismatch';END IF;
END $$;
'''+f'''
-- The explicit adopted policy retains the existing ten-digit allocation range.
INSERT INTO invoicing.reference_counters VALUES({physical},1000000000)
 ON CONFLICT(physical_account_id) DO UPDATE SET next_vs=greatest(invoicing.reference_counters.next_vs,excluded.next_vs);
UPDATE invoicing.reference_namespaces SET ready=true,history_sha256={lit(digest)},adopted_at=clock_timestamp() WHERE physical_account_id={physical};
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM invoicing.reference_namespaces WHERE physical_account_id={physical} AND ready AND history_sha256={lit(digest)}) THEN RAISE EXCEPTION 'adoption_namespace_missing';END IF; END $$;
COMMIT;
'''
a.output.write_text(sql);a.output.chmod(0o600)
print(f'Generated adoption for {len(rows)} historical exclusions; snapshot SHA-256 {digest}')
