BEGIN;
-- No historical invoice, claim or receiving-account identity is rewritten.
ALTER TABLE invoicing.receiving_accounts ALTER COLUMN reference_mode SET DEFAULT 'service';
CREATE TABLE invoicing.reference_namespaces(
 physical_account_id text PRIMARY KEY, ready boolean NOT NULL DEFAULT false,
 history_sha256 text CHECK(history_sha256 ~ '^[a-f0-9]{64}$'), adopted_at timestamptz,
 CHECK(NOT ready OR (history_sha256 IS NOT NULL AND adopted_at IS NOT NULL)));
CREATE TABLE invoicing.reference_exclusions(
 physical_account_id text NOT NULL REFERENCES invoicing.reference_namespaces,
 normalized_vs text NOT NULL CHECK(normalized_vs ~ '^(0|[1-9][0-9]{0,9})$'),
 source_ref text NOT NULL, payload_hash text NOT NULL,
 PRIMARY KEY(physical_account_id,normalized_vs));
INSERT INTO invoicing.reference_namespaces(physical_account_id,ready,history_sha256,adopted_at)
 SELECT physical_account_id,NOT bool_or(reference_mode='banksync'),
 CASE WHEN NOT bool_or(reference_mode='banksync') THEN repeat('0',64) END,
 CASE WHEN NOT bool_or(reference_mode='banksync') THEN now() END
 FROM invoicing.receiving_accounts GROUP BY physical_account_id;
ALTER TABLE invoicing.reference_namespaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoicing.reference_exclusions ENABLE ROW LEVEL SECURITY;
CREATE POLICY namespace_scope ON invoicing.reference_namespaces TO invoicing_executor USING(
 EXISTS(SELECT 1 FROM invoicing.receiving_accounts r WHERE r.app_id=current_setting('invoicing.app_id',true) AND r.physical_account_id=reference_namespaces.physical_account_id));
CREATE POLICY exclusions_scope ON invoicing.reference_exclusions TO invoicing_executor USING(
 EXISTS(SELECT 1 FROM invoicing.receiving_accounts r WHERE r.app_id=current_setting('invoicing.app_id',true) AND r.physical_account_id=reference_exclusions.physical_account_id));
GRANT SELECT,INSERT ON invoicing.reference_namespaces TO invoicing_executor;
GRANT UPDATE(physical_account_id) ON invoicing.reference_namespaces TO invoicing_executor;
GRANT SELECT ON invoicing.reference_exclusions TO invoicing_executor;
CREATE OR REPLACE FUNCTION invoicing.service_reference(p_id uuid) RETURNS jsonb LANGUAGE plpgsql SET search_path=invoicing,pg_catalog AS $$
DECLARE a text:=current_setting('invoicing.app_id');i invoices;r receiving_accounts;claim payment_reference_claims;n bigint;requested text;adopted boolean;
BEGIN
 SELECT * INTO STRICT i FROM invoices WHERE app_id=a AND id=p_id FOR UPDATE;
 SELECT account.* INTO STRICT r FROM receiving_accounts account JOIN issuer_profiles s ON(s.app_id,s.account_id)=(account.app_id,account.id) WHERE s.app_id=a AND s.id=i.issuer_id;
 IF r.reference_mode NOT IN('service','banksync') THEN RAISE EXCEPTION 'service_reference_mode_required';END IF;
 -- The namespace row serializes all applications sharing a receiving identity.
 INSERT INTO reference_namespaces(physical_account_id,ready,history_sha256,adopted_at)
 VALUES(r.physical_account_id,r.reference_mode='service',CASE WHEN r.reference_mode='service' THEN repeat('0',64) END,CASE WHEN r.reference_mode='service' THEN now() END) ON CONFLICT DO NOTHING;
 SELECT ready INTO adopted FROM reference_namespaces WHERE physical_account_id=r.physical_account_id FOR UPDATE;
 IF NOT adopted THEN RAISE EXCEPTION 'reference_history_adoption_required';END IF;
 SELECT * INTO claim FROM payment_reference_claims WHERE app_id=a AND invoice_id=p_id;
 IF NOT FOUND THEN
  requested:=i.command->>'variable_symbol';
  IF requested IS NOT NULL THEN
   IF requested !~ '^\d{1,10}$' THEN RAISE EXCEPTION 'invalid_vs';END IF;
   requested:=regexp_replace(requested,'^0+(?=\d)','','g');
   IF EXISTS(SELECT 1 FROM reference_exclusions WHERE physical_account_id=r.physical_account_id AND normalized_vs=requested) THEN RAISE EXCEPTION 'reference_conflict';END IF;
   INSERT INTO payment_reference_claims VALUES(a,p_id,r.physical_account_id,requested,'service','service:'||p_id) ON CONFLICT DO NOTHING RETURNING * INTO claim;
   IF claim.invoice_id IS NULL THEN RAISE EXCEPTION 'reference_conflict';END IF;
  ELSE
   INSERT INTO reference_counters VALUES(r.physical_account_id,CASE WHEN r.reference_mode='banksync' THEN 1000000000 ELSE 1 END) ON CONFLICT(physical_account_id) DO UPDATE SET next_vs=greatest(reference_counters.next_vs,excluded.next_vs);
   LOOP
    UPDATE reference_counters SET next_vs=next_vs+1 WHERE physical_account_id=r.physical_account_id AND next_vs<=9999999999 RETURNING next_vs-1 INTO n;
    IF NOT FOUND THEN RAISE EXCEPTION 'reference_exhausted';END IF;
    IF EXISTS(SELECT 1 FROM reference_exclusions WHERE physical_account_id=r.physical_account_id AND normalized_vs=n::text) THEN CONTINUE;END IF;
    INSERT INTO payment_reference_claims VALUES(a,p_id,r.physical_account_id,n::text,'service','service:'||p_id) ON CONFLICT DO NOTHING RETURNING * INTO claim;
    EXIT WHEN claim.invoice_id IS NOT NULL;
   END LOOP;
  END IF;
 END IF;
 RETURN jsonb_build_object('reservation_id',claim.reservation_id,'normalized_vs',claim.normalized_vs,'physical_account_id',r.physical_account_id,'source_ref',(SELECT environment FROM applications WHERE id=a)||':'||p_id,'app_id',r.consumer_id,'payload_hash',i.payload_hash);
END $$;
-- All historical banksync configurations now require an owned claim as well.
CREATE OR REPLACE FUNCTION invoicing.issue(p_id uuid,p_reference jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path=invoicing,pg_catalog AS $$
#variable_conflict use_column
<<issuance>>
DECLARE a text:=current_setting('invoicing.app_id');i invoices;s issuer_profiles;b customers;account receiving_accounts;num bigint;year integer:=extract(year FROM now() AT TIME ZONE 'Europe/Prague');issued date:=(now() AT TIME ZONE 'Europe/Prague')::date;snap jsonb;
BEGIN
 SELECT * INTO STRICT i FROM invoices WHERE app_id=a AND id=p_id FOR UPDATE;IF i.issuance_state='issued' THEN RETURN invoice_view(i.id);END IF;IF i.issuance_state NOT IN('awaiting_reference','blocked') THEN RAISE EXCEPTION 'invalid_issuance_state';END IF;
 SELECT * INTO STRICT s FROM issuer_profiles WHERE app_id=a AND id=i.issuer_id;SELECT * INTO STRICT b FROM customers WHERE app_id=a AND id=i.customer_id;SELECT * INTO STRICT account FROM receiving_accounts WHERE app_id=a AND id=s.account_id;
 IF NOT s.confirmed OR NOT account.verified OR s.tax_regime<>'non_vat' THEN RAISE EXCEPTION 'configuration_required';END IF;
 IF EXISTS(SELECT 1 FROM reference_exclusions WHERE physical_account_id=account.physical_account_id AND normalized_vs=regexp_replace(p_reference->>'normalized_vs','^0+(?=\d)','','g')) AND NOT EXISTS(SELECT 1 FROM payment_reference_claims WHERE app_id=a AND invoice_id=i.id AND normalized_vs=p_reference->>'normalized_vs' AND reservation_id=p_reference->>'reservation_id') THEN RAISE EXCEPTION 'reference_conflict';END IF;
 IF account.reference_mode IN('service','banksync') AND NOT EXISTS(SELECT 1 FROM payment_reference_claims WHERE app_id=a AND invoice_id=i.id AND reservation_id=p_reference->>'reservation_id' AND normalized_vs=p_reference->>'normalized_vs') THEN RAISE EXCEPTION 'service_reference_required';END IF;
 IF account.reference_mode='provided' AND (p_reference->>'reservation_id' IS DISTINCT FROM 'provided:'||i.id::text OR regexp_replace(p_reference->>'normalized_vs','^0+(?=\d)','','g') IS DISTINCT FROM regexp_replace(i.command->>'variable_symbol','^0+(?=\d)','','g')) THEN RAISE EXCEPTION 'provided_reference_mismatch';END IF;
 IF account.reference_mode='banksync' AND i.command ? 'variable_symbol' AND regexp_replace(p_reference->>'normalized_vs','^0+(?=\d)','','g') IS DISTINCT FROM regexp_replace(i.command->>'variable_symbol','^0+(?=\d)','','g') THEN RAISE EXCEPTION 'requested_reference_mismatch';END IF;
 IF account.reference_mode='banksync' AND p_reference->>'reservation_id' LIKE 'provided:%' THEN RAISE EXCEPTION 'banksync_reference_required';END IF;
 IF p_reference->>'payload_hash' IS DISTINCT FROM i.payload_hash OR p_reference->>'app_id' IS DISTINCT FROM account.consumer_id OR p_reference->>'physical_account_id' IS DISTINCT FROM account.physical_account_id OR p_reference->>'source_ref' IS DISTINCT FROM (SELECT environment FROM applications WHERE id=a)||':'||i.id::text OR COALESCE(p_reference->>'normalized_vs','')!~'^\d{1,10}$' OR p_reference->>'reservation_id' IS NULL THEN RAISE EXCEPTION 'reference_mismatch';END IF;
 IF account.reference_mode<>'service' THEN INSERT INTO payment_reference_claims VALUES(a,i.id,account.physical_account_id,regexp_replace(p_reference->>'normalized_vs','^0+(?=\d)','','g'),account.reference_mode,p_reference->>'reservation_id') ON CONFLICT(app_id,invoice_id) DO NOTHING;END IF;
 INSERT INTO invoice_series VALUES(a,s.id,year,1) ON CONFLICT DO NOTHING;UPDATE invoice_series SET next_number=next_number+1 WHERE app_id=a AND issuer_id=s.id AND invoice_series.year=issuance.year RETURNING next_number-1 INTO num;
 snap:=jsonb_build_object('simulation',(SELECT environment='simulation' FROM applications WHERE id=a),'brand_name',a,'number',s.series_prefix||'-'||year||'-'||lpad(num::text,6,'0'),'issued_on',issued,'due_on',issued+s.due_days,'issuer',s.profile,'buyer',b.profile,'owner_email',s.owner_email,'account',to_jsonb(account)-'health_as_of'-'observation_status'-'observed_through','reference',p_reference||jsonb_build_object('mode',account.reference_mode),'command',i.command,'total_minor',i.total_minor::text,'tax_regime',s.tax_regime);
 UPDATE invoices SET issuance_state='issued',number=snap->>'number',issued_on=issued,due_on=issued+s.due_days,snapshot=snap,reference_id=p_reference->>'reservation_id',physical_account_id=account.physical_account_id,normalized_vs=regexp_replace(p_reference->>'normalized_vs','^0+(?=\d)','','g'),incident=NULL,aggregate_version=aggregate_version+1 WHERE app_id=a AND id=i.id;
 PERFORM emit(i.customer_id,'invoice.issued',i.aggregate_version+1,invoice_view(i.id));PERFORM refresh_customer(i.customer_id);RETURN invoice_view(i.id);
END $$;
COMMIT;
