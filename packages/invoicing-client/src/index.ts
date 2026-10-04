export type Minor = string;
export interface BillingProfile {legal_name:string;party_type:'company'|'person';country_code:string;company_id:string|null;tax_id:string|null;address_line:string;city:string;postal_code:string;email:string;registry_source?:'ares'|'manual';retrieved_at?:string;registry_updated_at?:string;registry_hash?:string;field_origins?:Record<string,'registry'|'manual'>}
export interface InvoiceLine {source_line_id:string;description:string;group_label?:string|null;quantity:string;unit_minor:Minor}
export interface InvoiceCommand {customer_id:string;issuer_profile_id:string;source_ref:string;kind:'one_off'|'monthly'|'recurring';variable_symbol?:string;currency:'CZK';lines:InvoiceLine[];period_start?:string|null;period_end_exclusive?:string|null;service_date?:string|null;delivery_policy:'automatic_customer_copy_owner'|'owner_approval'}
export interface Invoice {invoice_id:string;customer_id:string;issuance_state:'draft'|'awaiting_reference'|'blocked'|'issued'|'cancelled_draft';artifact_state:'pending'|'rendering'|'ready'|'failed';number:string|null;currency:'CZK';total_minor:Minor;allocated_minor:Minor;outstanding_minor:Minor;payment_state:'unpaid'|'partially_paid'|'paid';payment_version:number;due_on:string|null;overdue:boolean;paid_at:string|null;as_of:string;reconciliation_required:boolean;delivery_state:string;[key:string]:unknown}
export interface BillingStatus {customer_id:string;billing_version:number;as_of:string;currency:'CZK';open_total_minor:Minor;overdue_total_minor:Minor;oldest_due_on:string|null;overdue_invoices:{invoice_id:string;outstanding_minor:Minor;due_on:string}[];next_due_at:string|null;reconciliation_required:boolean;bank_observation_status:'healthy'|'degraded'|'unknown';bank_observed_through:string|null}
export type EventType='invoice.issued'|'invoice.document_ready'|'invoice.payment_changed'|'invoice.overdue'|'invoice.delivery_changed'|'customer.billing_status_changed';
export interface InvoicingEvent {event_id:string;delivery_id:string;event_type:EventType;event_version:1;occurred_at:string;app_id:string;customer_id:string;aggregate_version:number;data:Record<string,unknown>}
export interface ScheduleCommand {customer_id:string;issuer_profile_id:string;plan:InvoiceCommand;interval:'month'|'year';interval_count:number;anchor_on:string;starts_on:string;ends_before?:string|null;timezone:'Europe/Prague';pause_policy:'skip'|'defer'}
export class InvoicingError extends Error {readonly status:number;readonly code:string;constructor(status:number,code:string){super(code);this.status=status;this.code=code;}}
export class InvoicingClient {
 private readonly origin:URL;private readonly transport:typeof fetch;
 private readonly options:{baseUrl:string;token:string;fetch?:typeof fetch};
 constructor(options:{baseUrl:string;token:string;fetch?:typeof fetch}){this.options=options;this.origin=new URL(options.baseUrl);if(this.origin.protocol!=='https:'||this.origin.username||this.origin.password||this.origin.search||this.origin.hash)throw Error('invalid_service_origin');this.transport=options.fetch??fetch;}
 async request<T>(path:string,method='GET',body?:unknown,key?:string):Promise<T>{const response=await this.raw(path,method,body,key);return response.json() as Promise<T>;}
 async raw(path:string,method='GET',body?:unknown,key?:string){if(!path.startsWith('/')||path.startsWith('//'))throw Error('invalid_path');const endpoint=new URL(path,this.origin);if(endpoint.origin!==this.origin.origin)throw Error('invalid_path');const r=await this.transport(endpoint,{method,redirect:'manual',signal:AbortSignal.timeout(15000),headers:{Authorization:`Bearer ${this.options.token}`,'Content-Type':'application/json',...(key?{'Idempotency-Key':key}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok){let code='service_unavailable';try{code=(await r.json() as {error:string}).error??code}catch{}throw new InvoicingError(r.status,code)}return r;}
 createInvoice(command:InvoiceCommand,key:string){return this.request<{invoice_id:string;issuance_state:string;status_url:string}>('/invoices','POST',command,key)}
 invoice(id:string){return this.request<Invoice>(`/invoices/${encodeURIComponent(id)}`)}
 pdf(id:string){return this.raw(`/invoices/${encodeURIComponent(id)}/pdf`)}
 deliver(id:string,key:string){return this.request(`/invoices/${encodeURIComponent(id)}/deliver`,'POST',{},key)}
 billingStatus(customer:string){return this.request<BillingStatus>(`/customers/${encodeURIComponent(customer)}/billing-status`)}
 events(cursor:string='0'){return this.request<{events:(InvoicingEvent&{cursor:string})[];cursor:string;high_water:string}>(`/events?cursor=${encodeURIComponent(cursor)}`)}
 saveProfile(customer:string,profile:BillingProfile,version:number){return this.request(`/customers/${encodeURIComponent(customer)}/profile`,'PUT',{profile,version})}
 profile(customer:string){return this.request<{profile:BillingProfile;version:number}>(`/customers/${encodeURIComponent(customer)}/profile`)}
 companyLookup(ico:string){return this.request<Record<string,unknown>>(`/company-lookup?country=CZ&ico=${encodeURIComponent(ico)}`)}
 schedule(command:ScheduleCommand,key:string){return this.request('/schedules','POST',command,key)}
 updateSchedule(id:string,change:Record<string,unknown>){return this.request(`/schedules/${encodeURIComponent(id)}`,'PATCH',change)}
}
const bytes=(v:string)=>new TextEncoder().encode(v);
export async function signInvoicingWebhook(body:string,deliveryId:string,secret:string,timestamp=Math.floor(Date.now()/1000)){
 const key=await crypto.subtle.importKey('raw',bytes(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);const signature=new Uint8Array(await crypto.subtle.sign('HMAC',key,bytes(`${timestamp}.${deliveryId}.${body}`)));return {timestamp:String(timestamp),signature:[...signature].map(v=>v.toString(16).padStart(2,'0')).join('')};
}
export async function verifyInvoicingWebhook(args:{bodyBytes:Uint8Array;headers:Headers;appId:string;keys:Record<string,{secret:string;expiresAt?:number}>;nowSeconds?:number}):Promise<InvoicingEvent>{
 if(args.bodyBytes.length>65536)throw Error('webhook_too_large');const h=args.headers,t=h.get('X-Invoicing-Timestamp')??'',id=h.get('X-Invoicing-Delivery-Id')??'',kid=h.get('X-Invoicing-Key-Id')??'',sig=h.get('X-Invoicing-Signature')??'',now=args.nowSeconds??Math.floor(Date.now()/1000),material=args.keys[kid];
 if(!/^\d{10}$/.test(t)||Math.abs(now-Number(t))>300||!material||(material.expiresAt!==undefined&&material.expiresAt<now)||!id||!/^[a-f0-9]{64}$/.test(sig))throw Error('webhook_auth');
 const raw=new TextDecoder('utf-8',{fatal:true}).decode(args.bodyBytes),expected=await signInvoicingWebhook(raw,id,material.secret,Number(t));let diff=0;for(let i=0;i<64;i++)diff|=sig.charCodeAt(i)^expected.signature.charCodeAt(i);if(diff)throw Error('webhook_signature');
 const e=JSON.parse(raw) as InvoicingEvent;if(e.delivery_id!==id||e.app_id!==args.appId||e.event_version!==1||!['invoice.issued','invoice.document_ready','invoice.payment_changed','invoice.overdue','invoice.delivery_changed','customer.billing_status_changed'].includes(e.event_type)||!Number.isSafeInteger(e.aggregate_version)||e.aggregate_version<1||typeof e.event_id!=='string'||typeof e.customer_id!=='string'||!e.data||typeof e.data!=='object'||!Number.isFinite(Date.parse(e.occurred_at)))throw Error('webhook_schema');
 if(e.event_type==='customer.billing_status_changed'){const d=e.data as unknown as BillingStatus;if(d.customer_id!==e.customer_id||d.billing_version!==e.aggregate_version||!/^\d+$/.test(d.open_total_minor)||!/^\d+$/.test(d.overdue_total_minor)||!['healthy','degraded','unknown'].includes(d.bank_observation_status)||!Array.isArray(d.overdue_invoices)||!Number.isFinite(Date.parse(d.as_of)))throw Error('webhook_schema');}
 return e;
}
