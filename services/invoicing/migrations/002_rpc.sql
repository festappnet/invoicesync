BEGIN;
CREATE FUNCTION invoicing.emit(p_customer text,p_type text,p_version bigint,p_data jsonb) RETURNS void LANGUAGE plpgsql SET search_path=invoicing,pg_catalog AS $$
DECLARE a text:=current_setting('invoicing.app_id');n bigint;e uuid:=gen_random_uuid();d uuid:=gen_random_uuid();b jsonb;
BEGIN
 UPDATE applications SET event_counter=event_counter+1 WHERE id=a RETURNING event_counter INTO n;
 b:=jsonb_build_object('event_id',e,'delivery_id',d,'event_type',p_type,'event_version',1,'occurred_at',now(),'app_id',a,'customer_id',p_customer,'aggregate_version',p_version,'data',CASE WHEN p_type LIKE 'invoice.%' THEN p_data-'snapshot' ELSE p_data END);
 INSERT INTO integration_events VALUES(a,e,n,b);INSERT INTO webhook_outbox(app_id,id,event_id,body) VALUES(a,d,e,b::text);
END $$;
CREATE FUNCTION invoicing.invoice_view(p_id uuid) RETURNS jsonb LANGUAGE sql SET search_path=invoicing,pg_catalog AS $$
 SELECT jsonb_build_object('invoice_id',id,'customer_id',customer_id,'issuance_state',issuance_state,'artifact_state',artifact_state,'delivery_state',delivery_state,'deliveries',(SELECT COALESCE(jsonb_agg(jsonb_build_object('recipient_role',d.recipient_role,'state',d.state,'incident',d.incident) ORDER BY d.created_at,d.id),'[]') FROM delivery_outbox d WHERE d.app_id=i.app_id AND d.invoice_id=i.id),'number',number,'total_minor',total_minor::text,'allocated_minor',allocated_minor::text,'outstanding_minor',(total_minor-allocated_minor)::text,'currency',currency,'payment_state',CASE WHEN allocated_minor=total_minor THEN 'paid' WHEN allocated_minor>0 THEN 'partially_paid' ELSE 'unpaid' END,'payment_version',payment_version,'paid_at',paid_at,'due_on',due_on,'overdue',COALESCE(due_on<(now() AT TIME ZONE 'Europe/Prague')::date AND allocated_minor<total_minor,false),'as_of',now(),'reconciliation_required',EXISTS(SELECT 1 FROM bank_movements m WHERE m.app_id=i.app_id AND m.physical_account_id=i.physical_account_id AND m.normalized_vs=i.normalized_vs AND m.reconciliation_required),'snapshot',snapshot,'incident',incident) FROM invoices i WHERE id=p_id AND app_id=current_setting('invoicing.app_id')
$$;
CREATE FUNCTION invoicing.refresh_customer(p_customer text) RETURNS jsonb LANGUAGE plpgsql SET search_path=invoicing,pg_catalog AS $$
DECLARE a text:=current_setting('invoicing.app_id');c customers;v jsonb;old jsonb;health text;watermark timestamptz;
BEGIN
 SELECT * INTO STRICT c FROM customers WHERE app_id=a AND id=p_customer FOR UPDATE;
 SELECT CASE WHEN count(*)=0 OR bool_or(observation_status='unknown' OR health_as_of IS NULL OR health_as_of<now()-interval '10 minutes') THEN 'unknown' WHEN bool_or(observation_status='degraded') THEN 'degraded' ELSE 'healthy' END,min(observed_through) INTO health,watermark FROM receiving_accounts WHERE app_id=a;
 SELECT jsonb_build_object('customer_id',p_customer,'currency','CZK','open_total_minor',COALESCE(sum(total_minor-allocated_minor),0)::text,'overdue_total_minor',COALESCE(sum(total_minor-allocated_minor) FILTER(WHERE due_on<(now() AT TIME ZONE 'Europe/Prague')::date),0)::text,'oldest_due_on',min(due_on) FILTER(WHERE due_on<(now() AT TIME ZONE 'Europe/Prague')::date),'overdue_invoices',COALESCE((SELECT jsonb_agg(jsonb_build_object('invoice_id',debt.id,'outstanding_minor',(debt.total_minor-debt.allocated_minor)::text,'due_on',debt.due_on) ORDER BY debt.due_on,debt.id) FROM (SELECT id,total_minor,allocated_minor,due_on FROM invoices WHERE app_id=a AND customer_id=p_customer AND issuance_state='issued' AND total_minor>allocated_minor AND due_on<(now() AT TIME ZONE 'Europe/Prague')::date ORDER BY due_on,id LIMIT 100) debt),'[]'),'next_due_at',min((due_on+1)::timestamp AT TIME ZONE 'Europe/Prague') FILTER(WHERE due_on>=(now() AT TIME ZONE 'Europe/Prague')::date),'reconciliation_required',EXISTS(SELECT 1 FROM bank_movements WHERE app_id=a AND reconciliation_required),'bank_observation_status',health,'bank_observed_through',watermark) INTO v FROM invoices WHERE app_id=a AND customer_id=p_customer AND issuance_state='issued' AND total_minor>allocated_minor;
 old:=c.status_snapshot-'as_of'-'billing_version';
 IF old IS DISTINCT FROM v THEN c.billing_version:=c.billing_version+1;v:=v||jsonb_build_object('billing_version',c.billing_version,'as_of',now());UPDATE customers SET billing_version=c.billing_version,status_snapshot=v WHERE app_id=a AND id=p_customer;PERFORM emit(p_customer,'customer.billing_status_changed',c.billing_version,v); ELSE v:=c.status_snapshot||jsonb_build_object('as_of',now());UPDATE customers SET status_snapshot=v WHERE app_id=a AND id=p_customer; END IF;
 RETURN v;
END $$;
CREATE FUNCTION invoicing.validate_profile(p jsonb) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF p IS NULL OR p->>'party_type' NOT IN('company','person') OR length(COALESCE(p->>'legal_name','')) NOT BETWEEN 1 AND 500 OR length(COALESCE(p->>'city','')) NOT BETWEEN 1 AND 200 OR length(COALESCE(p->>'postal_code','')) NOT BETWEEN 1 AND 20 OR p->>'country_code'<>'CZ' OR COALESCE(p->>'email','')!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' OR (p->>'party_type'='company' AND COALESCE(p->>'company_id','')!~'^\d{8}$') THEN RAISE EXCEPTION 'profile_incomplete' USING ERRCODE='22023'; END IF;
END $$;
CREATE FUNCTION invoicing.accept_invoice(p jsonb,p_key text) RETURNS uuid LANGUAGE plpgsql SET search_path=invoicing,pg_catalog AS $$
DECLARE a text:=current_setting('invoicing.app_id');h text:=encode(sha256(convert_to(p::text,'UTF8')),'hex');i invoices;line jsonb;total numeric:=0;issuer issuer_profiles;buyer customers;
BEGIN
 IF length(COALESCE(p_key,'')) NOT BETWEEN 1 AND 255 OR length(COALESCE(p->>'source_ref','')) NOT BETWEEN 1 AND 255 OR p->>'currency'<>'CZK' OR p->>'kind' NOT IN('one_off','monthly','recurring') OR p->>'delivery_policy' NOT IN('automatic_customer_copy_owner','owner_approval') OR jsonb_typeof(p->'lines')<>'array' OR jsonb_array_length(p->'lines') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'invoice_invalid' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(a||':'||(p->>'customer_id'),0));
 SELECT * INTO i FROM invoices WHERE app_id=a AND (idempotency_key=p_key OR (customer_id=p->>'customer_id' AND source_ref=p->>'source_ref'));
 IF FOUND THEN IF i.payload_hash<>h THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='23505'; END IF;RETURN i.id;END IF;
 SELECT * INTO STRICT issuer FROM issuer_profiles WHERE app_id=a AND id=p->>'issuer_profile_id';SELECT * INTO STRICT buyer FROM customers WHERE app_id=a AND id=p->>'customer_id';
 PERFORM validate_profile(buyer.profile);PERFORM validate_profile(issuer.profile);
 IF NOT issuer.confirmed OR issuer.tax_regime<>'non_vat' OR NOT EXISTS(SELECT 1 FROM receiving_accounts WHERE app_id=a AND id=issuer.account_id AND verified) THEN RAISE EXCEPTION 'issuer_configuration_required' USING ERRCODE='22023';END IF;
 IF (SELECT reference_mode FROM receiving_accounts WHERE app_id=a AND id=issuer.account_id)='provided' AND COALESCE(p->>'variable_symbol','')!~'^\d{1,10}$' THEN RAISE EXCEPTION 'provided_variable_symbol_required' USING ERRCODE='22023';END IF;
 IF (SELECT reference_mode FROM receiving_accounts WHERE app_id=a AND id=issuer.account_id)='service' AND p ? 'variable_symbol' THEN RAISE EXCEPTION 'server_allocated_variable_symbol' USING ERRCODE='22023';END IF;
 IF p->>'delivery_policy'<>(SELECT delivery_policy FROM applications WHERE id=a) THEN RAISE EXCEPTION 'delivery_policy_conflict' USING ERRCODE='22023';END IF;
 FOR line IN SELECT value FROM jsonb_array_elements(p->'lines') LOOP
  IF COALESCE(line->>'quantity','')!~'^[1-9]\d{0,9}$' OR COALESCE(line->>'unit_minor','')!~'^\d{1,12}$' OR length(COALESCE(line->>'description','')) NOT BETWEEN 1 AND 10000 OR length(COALESCE(line->>'source_line_id','')) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'line_invalid' USING ERRCODE='22023';END IF;
  total:=total+(line->>'quantity')::numeric*(line->>'unit_minor')::numeric;
 END LOOP;
 IF total NOT BETWEEN 1 AND 999999999999 THEN RAISE EXCEPTION 'amount_range' USING ERRCODE='22023';END IF;
 INSERT INTO invoices(app_id,customer_id,issuer_id,source_ref,idempotency_key,payload_hash,command,currency,total_minor) VALUES(a,buyer.id,issuer.id,p->>'source_ref',p_key,h,p,'CZK',total) RETURNING * INTO i;
 FOR line IN SELECT value FROM jsonb_array_elements(p->'lines') LOOP INSERT INTO invoice_lines VALUES(a,i.id,line->>'source_line_id',line->>'description',line->>'group_label',(line->>'quantity')::bigint,(line->>'unit_minor')::bigint);END LOOP;
 RETURN i.id;
END $$;
CREATE FUNCTION invoicing.service_reference(p_id uuid) RETURNS jsonb LANGUAGE plpgsql SET search_path=invoicing,pg_catalog AS $$
DECLARE a text:=current_setting('invoicing.app_id');i invoices;r receiving_accounts;claim payment_reference_claims;n bigint;
BEGIN
 SELECT * INTO STRICT i FROM invoices WHERE app_id=a AND id=p_id FOR UPDATE;
 SELECT account.* INTO STRICT r FROM receiving_accounts account JOIN issuer_profiles s ON(s.app_id,s.account_id)=(account.app_id,account.id) WHERE s.app_id=a AND s.id=i.issuer_id;
 IF r.reference_mode<>'service' THEN RAISE EXCEPTION 'service_reference_mode_required';END IF;
 SELECT * INTO claim FROM payment_reference_claims WHERE app_id=a AND invoice_id=p_id;
 IF NOT FOUND THEN
  INSERT INTO reference_counters VALUES(r.physical_account_id,1) ON CONFLICT DO NOTHING;
  FOR tries IN 1..100 LOOP
   UPDATE reference_counters SET next_vs=next_vs+1 WHERE physical_account_id=r.physical_account_id AND next_vs<=9999999999 RETURNING next_vs-1 INTO n;
   IF NOT FOUND THEN RAISE EXCEPTION 'reference_exhausted';END IF;
   INSERT INTO payment_reference_claims VALUES(a,p_id,r.physical_account_id,n::text,'service','service:'||p_id) ON CONFLICT DO NOTHING RETURNING * INTO claim;
   EXIT WHEN FOUND;
  END LOOP;
  IF claim.invoice_id IS NULL THEN RAISE EXCEPTION 'reference_retry_required';END IF;
 END IF;
 RETURN jsonb_build_object('reservation_id',claim.reservation_id,'normalized_vs',claim.normalized_vs,'physical_account_id',r.physical_account_id,'source_ref',(SELECT environment FROM applications WHERE id=a)||':'||p_id,'app_id',r.consumer_id,'payload_hash',i.payload_hash);
END $$;
CREATE FUNCTION invoicing.issue(p_id uuid,p_reference jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path=invoicing,pg_catalog AS $$
#variable_conflict use_column
<<issuance>>
DECLARE a text:=current_setting('invoicing.app_id');i invoices;s issuer_profiles;b customers;account receiving_accounts;num bigint;year integer:=extract(year FROM now() AT TIME ZONE 'Europe/Prague');issued date:=(now() AT TIME ZONE 'Europe/Prague')::date;snap jsonb;
BEGIN
 SELECT * INTO STRICT i FROM invoices WHERE app_id=a AND id=p_id FOR UPDATE;IF i.issuance_state='issued' THEN RETURN invoice_view(i.id);END IF;IF i.issuance_state NOT IN('awaiting_reference','blocked') THEN RAISE EXCEPTION 'invalid_issuance_state';END IF;
 SELECT * INTO STRICT s FROM issuer_profiles WHERE app_id=a AND id=i.issuer_id;SELECT * INTO STRICT b FROM customers WHERE app_id=a AND id=i.customer_id;SELECT * INTO STRICT account FROM receiving_accounts WHERE app_id=a AND id=s.account_id;
 IF NOT s.confirmed OR NOT account.verified OR s.tax_regime<>'non_vat' THEN RAISE EXCEPTION 'configuration_required';END IF;
 IF account.reference_mode='service' AND NOT EXISTS(SELECT 1 FROM payment_reference_claims WHERE app_id=a AND invoice_id=i.id AND reservation_id=p_reference->>'reservation_id' AND normalized_vs=p_reference->>'normalized_vs') THEN RAISE EXCEPTION 'service_reference_required';END IF;
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
CREATE FUNCTION invoicing.enqueue_delivery(p_id uuid,p_dedupe text,p_approve boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SET search_path=invoicing,pg_catalog AS $$
DECLARE a text:=current_setting('invoicing.app_id');i invoices;hash text;customer text;owner text;policy text;recipient text;role text;
BEGIN
 SELECT * INTO STRICT i FROM invoices WHERE app_id=a AND id=p_id FOR UPDATE;
 IF i.snapshot->>'simulation'='true' THEN RETURN;END IF;
 SELECT sha256 INTO STRICT hash FROM invoice_artifacts WHERE app_id=a AND invoice_id=p_id;
 customer:=lower(i.snapshot#>>'{buyer,email}');owner:=lower(i.snapshot->>'owner_email');policy:=i.command->>'delivery_policy';
 FOR recipient,role IN SELECT customer,'customer' UNION ALL SELECT owner,'owner' WHERE owner<>customer LOOP
  INSERT INTO delivery_outbox(app_id,invoice_id,dedupe_key,recipient,recipient_role,artifact_hash,state) VALUES(a,p_id,p_dedupe,recipient,role,hash,CASE WHEN policy='owner_approval' AND role='customer' AND NOT p_approve THEN 'approval_required' ELSE 'pending' END) ON CONFLICT DO NOTHING;
 END LOOP;
 UPDATE invoices SET delivery_state='pending' WHERE app_id=a AND id=p_id;
END $$;
CREATE FUNCTION invoicing.match_movement(p_id uuid,p_manual_invoice uuid DEFAULT NULL) RETURNS text LANGUAGE plpgsql SET search_path=invoicing,pg_catalog AS $$
DECLARE a text:=current_setting('invoicing.app_id');m bank_movements;i invoices;r receiving_accounts;alloc bigint;outcome text:='reconciliation_required';
BEGIN
 SELECT * INTO STRICT m FROM bank_movements WHERE id=p_id FOR UPDATE;
 SELECT * INTO STRICT r FROM receiving_accounts WHERE app_id=a AND physical_account_id=m.physical_account_id AND instance_id=m.instance_id LIMIT 1;
 IF m.amount_minor<=0 OR m.identity_kind<>'movement' OR m.payload->>'source'<>'fio_api' OR NOT r.verified OR (m.payload->>'date')::timestamptz<r.activation_at OR m.currency<>'CZK' OR COALESCE((m.payload->>'reference_conflict')::boolean,false) THEN RETURN outcome;END IF;
 IF NOT m.reconciliation_required AND m.unallocated_minor=0 THEN RETURN 'duplicate_movement';END IF;
 SELECT * INTO i FROM invoices WHERE app_id=a AND physical_account_id=m.physical_account_id AND issuance_state='issued' AND (CASE WHEN p_manual_invoice IS NULL THEN normalized_vs=m.normalized_vs ELSE invoices.id=p_manual_invoice END) FOR UPDATE;
 IF NOT FOUND THEN RETURN outcome;END IF;
 IF m.unallocated_minor<m.amount_minor OR EXISTS(SELECT 1 FROM payment_allocations WHERE movement_id=m.id) THEN RETURN 'already_allocated';END IF;
 alloc:=least(m.unallocated_minor,i.total_minor-i.allocated_minor);
 IF alloc>0 THEN
  INSERT INTO payment_allocations VALUES(a,m.id,i.id,alloc,now());
  UPDATE invoices SET allocated_minor=allocated_minor+alloc,payment_version=payment_version+1,aggregate_version=aggregate_version+1,paid_at=CASE WHEN allocated_minor+alloc=total_minor THEN now() ELSE NULL END WHERE app_id=a AND invoices.id=i.id;
  PERFORM emit(i.customer_id,'invoice.payment_changed',i.aggregate_version+1,invoice_view(i.id));
 END IF;
 UPDATE bank_movements SET unallocated_minor=unallocated_minor-alloc,reconciliation_required=unallocated_minor>alloc WHERE id=m.id;
 PERFORM refresh_customer(i.customer_id);RETURN CASE WHEN m.unallocated_minor>alloc THEN 'overpayment' ELSE 'allocated' END;
END $$;
CREATE FUNCTION invoicing.bank_receive(p jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path=invoicing,pg_catalog AS $$
DECLARE a text:=current_setting('invoicing.app_id');r receiving_accounts;old bank_inbox;hash text:=p->>'payload_hash';d jsonb:=p->'envelope'->'data';delivery text:=p->'envelope'->>'delivery_id';m bank_movements;i invoices;amount bigint;alloc bigint;vs text;movement text;outcome text:='reconciliation_required';receipt jsonb;
BEGIN
 SELECT * INTO STRICT r FROM receiving_accounts WHERE app_id=a AND bank_account_id=(d->>'bank_account_id')::integer AND instance_id=p->>'instance_id' AND consumer_id=p->>'consumer_id';
 PERFORM pg_advisory_xact_lock(hashtextextended(r.instance_id||':'||r.consumer_id||':'||delivery,0));
 SELECT * INTO old FROM bank_inbox WHERE instance_id=r.instance_id AND consumer_id=r.consumer_id AND delivery_id=delivery;
 IF FOUND THEN IF old.payload_hash<>hash THEN RAISE EXCEPTION 'bank_delivery_conflict' USING ERRCODE='23505';END IF;RETURN old.receipt;END IF;
 amount:=(d->>'amount_cents')::bigint;vs:=COALESCE(d->>'raw_vs',d->>'vs');IF vs~'^\d{1,10}$' THEN vs:=regexp_replace(vs,'^0+(?=\d)','','g');ELSE vs:=NULL;END IF;
 movement:=CASE WHEN d->>'identity_kind'='movement' THEN d->>'transaction_id' ELSE 'unverified:'||delivery END;
 IF movement IS NULL THEN movement:='unverified:'||delivery;END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(r.instance_id||':'||r.physical_account_id||':'||movement,0));
 SELECT * INTO m FROM bank_movements WHERE instance_id=r.instance_id AND physical_account_id=r.physical_account_id AND movement_id=movement FOR UPDATE;
 IF FOUND THEN
  IF m.amount_minor<>amount OR m.currency<>d->>'currency' OR m.normalized_vs IS DISTINCT FROM vs THEN RAISE EXCEPTION 'movement_identity_conflict';END IF;
  outcome:=match_movement(m.id);
 ELSE
  INSERT INTO bank_movements(app_id,instance_id,physical_account_id,movement_id,currency,amount_minor,normalized_vs,identity_kind,unallocated_minor,payload) VALUES(a,r.instance_id,r.physical_account_id,movement,d->>'currency',amount,vs,d->>'identity_kind',greatest(amount,0),d) ON CONFLICT(instance_id,physical_account_id,movement_id) DO NOTHING RETURNING * INTO m;
  IF NOT FOUND THEN receipt:=jsonb_build_object('ok',true,'receipt_version',1,'delivery_id',delivery,'outcome','foreign_movement');INSERT INTO bank_inbox VALUES(a,r.instance_id,r.consumer_id,delivery,hash,receipt);RETURN receipt;END IF;
  outcome:=match_movement(m.id);
 END IF;
 receipt:=jsonb_build_object('ok',true,'receipt_version',1,'delivery_id',delivery,'outcome',outcome);INSERT INTO bank_inbox VALUES(a,r.instance_id,r.consumer_id,delivery,hash,receipt);RETURN receipt;
END $$;
CREATE FUNCTION invoicing_api.dispatch(p_op text,p_request jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=invoicing,pg_catalog AS $$
#variable_conflict use_column
<<rpc>>
DECLARE claims jsonb:=current_setting('request.jwt.claims',true)::jsonb;credential credentials;a text;scope text;i invoices;id uuid;result jsonb;row record;sch schedules;next_date date;months integer;yr integer;mo integer;day integer;
BEGIN
 IF claims->>'role' IS DISTINCT FROM 'invoicing_gateway' OR claims->>'aud' IS DISTINCT FROM 'invoicing-rpc' OR COALESCE((claims->>'exp')::bigint,0)<=extract(epoch FROM now()) THEN RAISE EXCEPTION 'workload_denied' USING ERRCODE='42501';END IF;
 SELECT * INTO credential FROM credentials WHERE jti_hash=encode(sha256(convert_to(claims->>'jti','UTF8')),'hex') AND revoked_at IS NULL AND expires_at>now() AND audience=claims->>'aud';IF NOT FOUND THEN RAISE EXCEPTION 'workload_revoked' USING ERRCODE='42501';END IF;
 a:=credential.app_id;PERFORM set_config('invoicing.app_id',a,true);PERFORM 1 FROM applications WHERE applications.id=a FOR UPDATE;
 scope:=CASE WHEN p_op IN('invoice_create','schedule_create','schedule_update','profile_save') THEN 'write' WHEN p_op='deliver' THEN 'deliver' WHEN p_op='bank_receive' THEN 'bank' WHEN p_op IN('invoice_get','customer_status','profile_get','events','artifact_get','lookup_permission','schedule_list','schedule_get') THEN 'read' ELSE 'jobs' END;
 IF NOT scope=ANY(credential.scopes) THEN RAISE EXCEPTION 'scope_denied' USING ERRCODE='42501';END IF;
 IF p_op='lookup_permission' THEN RETURN jsonb_build_object('app_id',a);END IF;
 IF p_op='profile_get' THEN SELECT jsonb_build_object('profile',profile,'version',profile_version,'reference_mode',(SELECT reference_mode FROM receiving_accounts WHERE app_id=a LIMIT 1)) INTO result FROM customers WHERE app_id=a AND id=p_request->>'customer_id';
 ELSIF p_op='profile_save' THEN
  PERFORM validate_profile(p_request->'profile');UPDATE customers SET profile=p_request->'profile',profile_version=profile_version+1 WHERE app_id=a AND id=p_request->>'customer_id' AND profile_version=(p_request->>'version')::integer RETURNING jsonb_build_object('profile',profile,'version',profile_version) INTO result;IF NOT FOUND THEN RAISE EXCEPTION 'profile_version_conflict' USING ERRCODE='40001';END IF;INSERT INTO profile_history VALUES(a,p_request->>'customer_id',(result->>'version')::integer,p_request->'profile',now());
 ELSIF p_op='invoice_create' THEN id:=accept_invoice(p_request->'command',p_request->>'key');RETURN jsonb_build_object('invoice_id',id,'issuance_state',(SELECT issuance_state FROM invoices WHERE app_id=a AND invoices.id=rpc.id),'status_url','/invoices/'||id);
 ELSIF p_op='invoice_get' THEN result:=invoice_view((p_request->>'invoice_id')::uuid);
 ELSIF p_op='customer_status' THEN RETURN refresh_customer(p_request->>'customer_id');
 ELSIF p_op='events' THEN
  SELECT jsonb_build_object('high_water',event_counter::text,'cursor',COALESCE((SELECT max(cursor) FROM (SELECT cursor FROM integration_events WHERE app_id=a AND cursor>COALESCE((p_request->>'cursor')::bigint,0) ORDER BY cursor LIMIT 100) x),COALESCE((p_request->>'cursor')::bigint,0))::text,'events',COALESCE((SELECT jsonb_agg(body||jsonb_build_object('cursor',cursor::text) ORDER BY cursor) FROM (SELECT body,cursor FROM integration_events WHERE app_id=a AND cursor>COALESCE((p_request->>'cursor')::bigint,0) ORDER BY cursor LIMIT 100) x),'[]')) INTO result FROM applications WHERE applications.id=a;
 ELSIF p_op='artifact_get' THEN SELECT to_jsonb(x) INTO result FROM invoice_artifacts x WHERE app_id=a AND invoice_id=(p_request->>'invoice_id')::uuid;
 ELSIF p_op='issue_preview' THEN
  SELECT * INTO STRICT i FROM invoices WHERE app_id=a AND invoices.id=(p_request->>'invoice_id')::uuid;
  SELECT jsonb_build_object('simulation',(SELECT environment='simulation' FROM applications WHERE applications.id=a),'brand_name',a,'number',s.series_prefix||'-2099-999999','issued_on',(now() AT TIME ZONE 'Europe/Prague')::date,'due_on',(now() AT TIME ZONE 'Europe/Prague')::date+s.due_days,'issuer',s.profile,'buyer',b.profile,'owner_email',s.owner_email,'account',to_jsonb(r),'reference',jsonb_build_object('normalized_vs','9999999999','reservation_id','preflight'),'command',i.command,'total_minor',i.total_minor::text,'tax_regime',s.tax_regime) INTO result FROM issuer_profiles s JOIN receiving_accounts r ON(r.app_id,r.id)=(s.app_id,s.account_id) JOIN customers b ON b.app_id=a AND b.id=i.customer_id WHERE s.app_id=a AND s.id=i.issuer_id;
 ELSIF p_op='issue_list' THEN SELECT COALESCE(jsonb_agg(to_jsonb(x)),'[]') INTO result FROM (SELECT i.id AS invoice_id,i.payload_hash,i.command,s.account_id,r.bank_account_id,r.physical_account_id,r.reference_mode,(SELECT environment FROM applications WHERE applications.id=a)||':'||i.id::text AS source_ref FROM invoices i JOIN issuer_profiles s ON (s.app_id,s.id)=(i.app_id,i.issuer_id) JOIN receiving_accounts r ON(r.app_id,r.id)=(s.app_id,s.account_id) WHERE i.app_id=a AND i.issuance_state IN('awaiting_reference','blocked') AND COALESCE(i.incident,'') NOT IN('reference_conflict','reference_exhausted','invalid_vs','reference_forbidden') ORDER BY i.created_at LIMIT 5) x;
 ELSIF p_op='service_reference' THEN RETURN service_reference((p_request->>'invoice_id')::uuid);
 ELSIF p_op='issue' THEN RETURN issue((p_request->>'invoice_id')::uuid,p_request->'reference');
 ELSIF p_op='issue_failed' THEN UPDATE invoices SET issuance_state='blocked',incident=p_request->>'code' WHERE app_id=a AND invoices.id=(p_request->>'invoice_id')::uuid AND issuance_state<>'issued';RETURN '{}'::jsonb;
 ELSIF p_op='render_list' THEN SELECT COALESCE(jsonb_agg(to_jsonb(x)),'[]') INTO result FROM (SELECT id AS invoice_id,snapshot FROM invoices WHERE app_id=a AND issuance_state='issued' AND artifact_state<>'ready' ORDER BY created_at LIMIT 3) x;
 ELSIF p_op='artifact_ready' THEN
  SELECT * INTO STRICT i FROM invoices WHERE app_id=a AND invoices.id=(p_request->>'invoice_id')::uuid FOR UPDATE;
  IF i.artifact_state='ready' THEN SELECT sha256 INTO row FROM invoice_artifacts WHERE app_id=a AND invoice_id=i.id;IF row.sha256<>p_request->>'sha256' THEN RAISE EXCEPTION 'artifact_immutable';END IF;RETURN '{}'::jsonb;END IF;
  INSERT INTO invoice_artifacts VALUES(a,i.id,p_request->>'object_key',p_request->>'sha256',p_request->>'renderer_version',(p_request->>'bytes')::integer,now());UPDATE invoices SET artifact_state='ready',aggregate_version=aggregate_version+1 WHERE app_id=a AND invoices.id=i.id;PERFORM emit(i.customer_id,'invoice.document_ready',i.aggregate_version+1,invoice_view(i.id));PERFORM enqueue_delivery(i.id,'initial:'||i.id);RETURN '{}'::jsonb;
 ELSIF p_op='artifact_failed' THEN UPDATE invoices SET artifact_state='failed',incident=p_request->>'code' WHERE app_id=a AND invoices.id=(p_request->>'invoice_id')::uuid AND artifact_state<>'ready';RETURN '{}'::jsonb;
 ELSIF p_op='deliver' THEN IF length(COALESCE(p_request->>'key','')) NOT BETWEEN 1 AND 255 THEN RAISE EXCEPTION 'delivery_key_required' USING ERRCODE='22023';END IF;PERFORM enqueue_delivery((p_request->>'invoice_id')::uuid,p_request->>'key',true);UPDATE delivery_outbox SET state='pending' WHERE app_id=a AND invoice_id=(p_request->>'invoice_id')::uuid AND state='approval_required';RETURN '{}'::jsonb;
 ELSIF p_op='bank_receive' THEN RETURN bank_receive(p_request);
 ELSIF p_op='reconcile' THEN
  IF NOT 'reconcile'=ANY(credential.scopes) OR length(COALESCE(p_request->>'reason',''))<10 THEN RAISE EXCEPTION 'reconcile_denied' USING ERRCODE='42501';END IF;
  result:=jsonb_build_object('outcome',match_movement((p_request->>'movement_id')::uuid,(p_request->>'invoice_id')::uuid));
  INSERT INTO audit_events(app_id,kind,data) VALUES(a,'manual_payment_reconciliation',p_request||result);RETURN result;
 ELSIF p_op='reconcile_sweep' THEN
  FOR row IN SELECT id FROM bank_movements WHERE reconciliation_required ORDER BY id LIMIT 20 LOOP PERFORM match_movement(row.id);END LOOP;RETURN '{}'::jsonb;
 ELSIF p_op='health' THEN UPDATE receiving_accounts SET observation_status=p_request->>'bank_observation_status',health_as_of=now(),observed_through=(p_request->>'bank_observed_through')::timestamptz WHERE app_id=a AND bank_account_id=(p_request->>'bank_account_id')::integer;RETURN '{}'::jsonb;
 ELSIF p_op='overdue_sweep' THEN
  FOR i IN UPDATE invoices SET overdue_notified=true,aggregate_version=aggregate_version+1 WHERE app_id=a AND issuance_state='issued' AND due_on<(now() AT TIME ZONE 'Europe/Prague')::date AND allocated_minor<total_minor AND NOT overdue_notified RETURNING * LOOP PERFORM emit(i.customer_id,'invoice.overdue',i.aggregate_version,invoice_view(i.id));END LOOP;
  FOR row IN SELECT id FROM customers WHERE app_id=a AND id>COALESCE((SELECT overdue_customer_cursor FROM applications WHERE applications.id=a),'') ORDER BY id LIMIT 100 LOOP PERFORM refresh_customer(row.id);UPDATE applications SET overdue_customer_cursor=row.id WHERE applications.id=a;END LOOP;
  IF NOT EXISTS(SELECT 1 FROM customers WHERE app_id=a AND id>(SELECT overdue_customer_cursor FROM applications WHERE applications.id=a)) THEN UPDATE applications SET overdue_customer_cursor=NULL WHERE applications.id=a;END IF;
  RETURN '{}'::jsonb;
 ELSIF p_op='webhook_claim' THEN
  UPDATE webhook_outbox SET state='pending' WHERE app_id=a AND state='claimed' AND lease_until<now();
  SELECT * INTO row FROM webhook_outbox WHERE app_id=a AND state='pending' AND next_attempt_at<=now() ORDER BY next_attempt_at FOR UPDATE SKIP LOCKED LIMIT 1;IF NOT FOUND THEN RETURN NULL;END IF;
  UPDATE webhook_outbox SET state='claimed',fence=fence+1,attempts=attempts+1,lease_until=now()+interval '1 minute' WHERE app_id=a AND webhook_outbox.id=row.id RETURNING * INTO row;
  SELECT to_jsonb(row)||jsonb_build_object('callback_url',callback_url,'callback_key_id',callback_key_id) INTO result FROM applications WHERE applications.id=a;
 ELSIF p_op='webhook_complete' THEN UPDATE webhook_outbox SET state=CASE WHEN p_request->>'outcome'='delivered' THEN 'delivered' WHEN p_request->>'outcome'='terminal' OR attempts>=20 THEN 'terminal' ELSE 'pending' END,next_attempt_at=now()+make_interval(secs=>least(3600,(power(2,least(attempts,11))*random()+1)::integer)),lease_until=NULL WHERE app_id=a AND webhook_outbox.id=(p_request->>'id')::uuid AND fence=(p_request->>'fence')::integer AND state='claimed';RETURN '{}'::jsonb;
 ELSIF p_op='email_claim' THEN
  UPDATE delivery_outbox SET state=CASE WHEN state='sending' THEN 'unknown' ELSE 'pending' END WHERE app_id=a AND state IN('sending','claimed') AND lease_until<now();
  UPDATE delivery_outbox d SET state='failed',incident='recipient_suppressed' WHERE d.app_id=a AND d.state='pending' AND EXISTS(SELECT 1 FROM suppressed_recipients s WHERE s.app_id=a AND s.recipient=d.recipient);
  SELECT * INTO row FROM delivery_outbox WHERE app_id=a AND state='pending' ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1;IF NOT FOUND THEN RETURN NULL;END IF;
  UPDATE delivery_outbox SET state='claimed',worker=p_request->>'worker',fence=fence+1,lease_until=now()+interval '2 minutes' WHERE app_id=a AND delivery_outbox.id=row.id RETURNING * INTO row;
  SELECT to_jsonb(row)||jsonb_build_object('snapshot',snapshot,'artifact',(SELECT to_jsonb(x) FROM invoice_artifacts x WHERE x.app_id=a AND x.invoice_id=i.id)) INTO result FROM invoices i WHERE i.app_id=a AND i.id=row.invoice_id;
 ELSIF p_op IN('email_begin','email_accepted','email_failure') THEN
  UPDATE delivery_outbox SET state=CASE p_op WHEN 'email_begin' THEN 'sending' WHEN 'email_accepted' THEN 'accepted' ELSE CASE WHEN state='sending' THEN 'unknown' ELSE 'failed' END END,provider_id=CASE WHEN p_op='email_accepted' THEN p_request->>'provider_id' ELSE provider_id END,incident=p_request->>'code' WHERE app_id=a AND delivery_outbox.id=(p_request->>'id')::uuid AND worker=p_request->>'worker' AND fence=(p_request->>'fence')::integer AND lease_until>now() AND state=CASE WHEN p_op='email_begin' THEN 'claimed' ELSE 'sending' END RETURNING invoice_id INTO id;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery_fence_lost';END IF;SELECT * INTO i FROM invoices WHERE app_id=a AND invoices.id=rpc.id;UPDATE invoices SET aggregate_version=aggregate_version+1,delivery_state=(SELECT state FROM delivery_outbox WHERE app_id=a AND delivery_outbox.id=(p_request->>'id')::uuid) WHERE app_id=a AND invoices.id=rpc.id;PERFORM emit(i.customer_id,'invoice.delivery_changed',i.aggregate_version+1,invoice_view(i.id));RETURN '{}'::jsonb;
 ELSIF p_op='email_feedback' THEN
  SELECT * INTO STRICT row FROM delivery_outbox WHERE app_id=a AND delivery_outbox.id=(p_request->>'id')::uuid FOR UPDATE;
  IF row.provider_id IS NOT NULL AND row.provider_id<>p_request->>'provider_id' OR row.recipient<>p_request->>'recipient' OR p_request->>'state' NOT IN('accepted','delivered','bounced','complaint','failed') THEN RAISE EXCEPTION 'feedback_scope';END IF;
  INSERT INTO delivery_events VALUES(a,p_request->>'event_id',row.id,p_request->>'state') ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN RETURN '{}'::jsonb;END IF;
  IF row.state NOT IN('bounced','complaint','delivered') OR p_request->>'state' IN('bounced','complaint') THEN UPDATE delivery_outbox SET state=p_request->>'state',provider_id=p_request->>'provider_id' WHERE app_id=a AND delivery_outbox.id=row.id;END IF;
  IF p_request->>'state' IN('bounced','complaint') THEN INSERT INTO suppressed_recipients VALUES(a,row.recipient,p_request->>'state') ON CONFLICT DO NOTHING;END IF;
  SELECT * INTO i FROM invoices WHERE app_id=a AND invoices.id=row.invoice_id;UPDATE invoices SET aggregate_version=aggregate_version+1,delivery_state=(SELECT state FROM delivery_outbox WHERE app_id=a AND delivery_outbox.id=row.id) WHERE app_id=a AND invoices.id=i.id;PERFORM emit(i.customer_id,'invoice.delivery_changed',i.aggregate_version+1,invoice_view(i.id));RETURN '{}'::jsonb;
 ELSIF p_op='schedule_list' THEN SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.next_due_on),'[]') INTO result FROM (SELECT * FROM schedules WHERE app_id=a ORDER BY next_due_on,id LIMIT 100) x;
 ELSIF p_op='schedule_get' THEN SELECT to_jsonb(s) INTO result FROM schedules s WHERE app_id=a AND s.id=(p_request->>'schedule_id')::uuid;
 ELSIF p_op='schedule_create' THEN
  SELECT * INTO sch FROM schedules WHERE app_id=a AND idempotency_key=p_request->>'key';IF FOUND THEN IF sch.payload_hash<>encode(sha256(convert_to((p_request-'key')::text,'UTF8')),'hex') THEN RAISE EXCEPTION 'schedule_idempotency_conflict' USING ERRCODE='23505';END IF;RETURN to_jsonb(sch);END IF;
  IF p_request->>'timezone'<>'Europe/Prague' THEN RAISE EXCEPTION 'timezone_unsupported';END IF;
  -- Validate plan using a durable first occurrence only when due, not now.
  PERFORM validate_profile((SELECT profile FROM customers WHERE app_id=a AND customers.id=p_request->>'customer_id'));
  INSERT INTO schedules(app_id,command,idempotency_key,payload_hash,next_due_on,anchor_on,interval_kind,interval_count,ends_before,pause_policy) VALUES(a,p_request,p_request->>'key',encode(sha256(convert_to((p_request-'key')::text,'UTF8')),'hex'),(p_request->>'starts_on')::date,(p_request->>'anchor_on')::date,p_request->>'interval',(p_request->>'interval_count')::integer,(p_request->>'ends_before')::date,p_request->>'pause_policy') RETURNING * INTO sch;
  INSERT INTO schedule_revisions VALUES(a,sch.id,1,p_request);RETURN to_jsonb(sch);
 ELSIF p_op='schedule_update' THEN
  SELECT * INTO STRICT sch FROM schedules WHERE app_id=a AND schedules.id=(p_request->>'schedule_id')::uuid FOR UPDATE;
  IF sch.revision IS DISTINCT FROM (p_request->>'version')::integer THEN RAISE EXCEPTION 'schedule_version_conflict' USING ERRCODE='40001';END IF;IF sch.status='cancelled' THEN RAISE EXCEPTION 'schedule_cancelled';END IF;
  UPDATE schedules SET status=COALESCE(p_request->'change'->>'status',status),command=COALESCE(p_request->'change'->'command',command),revision=revision+1 WHERE app_id=a AND schedules.id=sch.id RETURNING * INTO sch;INSERT INTO schedule_revisions VALUES(a,sch.id,sch.revision,sch.command);
  IF sch.status='active' AND sch.pause_policy='skip' AND p_request->'change'->>'status'='active' THEN
   WHILE sch.next_due_on<(now() AT TIME ZONE 'Europe/Prague')::date LOOP
    next_date:=(date_trunc('month',sch.next_due_on)+make_interval(months=>sch.interval_count*CASE WHEN sch.interval_kind='year' THEN 12 ELSE 1 END))::date;
    sch.next_due_on:=next_date+least(extract(day FROM sch.anchor_on)::integer,extract(day FROM next_date+interval '1 month - 1 day')::integer)-1;
   END LOOP;UPDATE schedules SET next_due_on=sch.next_due_on WHERE app_id=a AND schedules.id=sch.id;
  END IF;RETURN to_jsonb(sch);
 ELSIF p_op='schedule_sweep' THEN
  FOR sch IN SELECT * FROM schedules WHERE app_id=a AND status='active' AND next_due_on<=(now() AT TIME ZONE 'Europe/Prague')::date AND (ends_before IS NULL OR next_due_on<ends_before) ORDER BY next_due_on FOR UPDATE SKIP LOCKED LIMIT 5 LOOP
   id:=accept_invoice((sch.command->'plan')||jsonb_build_object('source_ref','schedule:'||sch.id||':'||sch.next_due_on,'kind','recurring'),'schedule:'||sch.id||':'||sch.next_due_on);
   INSERT INTO schedule_occurrences VALUES(a,sch.id,sch.next_due_on,id,sch.revision) ON CONFLICT DO NOTHING;
   months:=sch.interval_count*CASE WHEN sch.interval_kind='year' THEN 12 ELSE 1 END;
   next_date:=(date_trunc('month',sch.next_due_on)+make_interval(months=>months))::date;
   day:=least(extract(day FROM sch.anchor_on)::integer,extract(day FROM next_date+interval '1 month - 1 day')::integer);next_date:=next_date+day-1;
   UPDATE schedules SET next_due_on=next_date WHERE app_id=a AND schedules.id=sch.id;
  END LOOP;RETURN '{}'::jsonb;
 ELSIF p_op='incidents' THEN SELECT jsonb_build_object('blocked_issuance',(SELECT count(*) FROM invoices WHERE app_id=a AND issuance_state='blocked'),'failed_artifacts',(SELECT count(*) FROM invoices WHERE app_id=a AND artifact_state='failed'),'unknown_delivery',(SELECT count(*) FROM delivery_outbox WHERE app_id=a AND state='unknown'),'terminal_webhooks',(SELECT count(*) FROM webhook_outbox WHERE app_id=a AND state='terminal'),'unmatched_movements',(SELECT count(*) FROM bank_movements WHERE app_id=a AND reconciliation_required)) INTO result;
 ELSE RAISE EXCEPTION 'unknown_operation' USING ERRCODE='22023';END IF;
 IF result IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002';END IF;RETURN result;
END $$;
DO $$ DECLARE r record; BEGIN FOR r IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN('invoicing','invoicing_api') LOOP EXECUTE format('ALTER FUNCTION %s OWNER TO invoicing_executor',r.signature); END LOOP; END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA invoicing,invoicing_api FROM PUBLIC;
GRANT USAGE ON SCHEMA invoicing_api TO invoicing_gateway;
GRANT EXECUTE ON FUNCTION invoicing_api.dispatch(text,jsonb) TO invoicing_gateway;
COMMIT;
