# Rollout manifest - 2026-10-04

User authorized production rollout and main publication on 2026-10-04, and confirmed
the issuer/account are the same as Mendelio. BankSync is the default reference mode.
Production evidence is recorded separately below; earlier local checks remain provenance.

## Required authority and configuration

| Owner | Required production evidence/configuration |
|---|---|
| Database operator | Dedicated invoicing gateway JWT role, executor ownership, exposed `invoicing_api` schema and registered aud/jti/expiry/scopes; migrations and backup authority |
| Issuer | Confirmed legal name/address/company ID, actual VAT regime, contact and due days; supported initial regime is non-VAT/CZK |
| Receiving account operator | Valid actual CZ IBAN, canonical physical-account identity, bank account ID, activation boundary and chosen reference mode/namespace |
| BankSync operator | Actual deployed v2 support, instance ID, consumer ID, subscription/pairing code, callback keys, fresh successful import evidence; source support alone is insufficient |
| Worker operator | Separate Worker, private R2 binding, RPC origin/API key, workload tokens, callback hostname allowlist, webhook keys and cron; no public bucket URLs |
| Mail operator | Verified SES sender, dedicated invoicing configuration set/tags and SNS/SQS feedback stream, scoped AWS secret bindings; keep recovery bindings intact |
| CatalogPilot owner | Trusted tenant/customer/issuer mappings, initial profile and projection, billing activation time and grace/freshness policy |

There are no placeholder production values in the source. `WORKLOADS_JSON` is a secret
array of app ID, registered workload token, BankSync HTTPS origin/token/account,
instance/consumer/pairing mapping, signature verification keys, outgoing webhook keys
and optional mail configuration. Store secrets through deployment secret bindings,
never in Git. `RPC_ORIGIN`, optional `RPC_APIKEY`, private `INVOICE_ARTIFACTS`,
`CALLBACK_HOSTS`, `ENVIRONMENT` and `LIVE_ACTIVATION` are service bindings.
CatalogPilot needs `INVOICING_ORIGIN`, `INVOICING_TOKEN`, `INVOICING_APP_ID` and
`INVOICING_WEBHOOK_KEYS` plus its existing RPC/owner bindings. Previous outgoing
verification keys must have a finite `expiresAt`; remove old BankSync secrets at the
end of the operator's rotation window.

## Ordered rollout operations

1. Inventory and back up current CatalogPilot finance/legacy invoices, service schema
   if present, BankSync D1 subscriptions/recovery state and permanent VS history.
   Record deployment SHA, schema versions, account/consumer identities and restore
   evidence without secret material. Inventory historical PDFs by object key/hash;
   missing artifacts cannot be reconstructed as original bytes or silently replaced.
2. Apply BankSync `0012_payment_references.sql` additively. It preserves schema 11 v2
   import/delivery behavior. Account health is usable without enrollment in the VS
   registry. New registries and restored backups start locked. For optional BankSync
   references, map account aliases, grant the consumer, import known history and
   resolve collisions before an explicit `registry_verified:true` activation.
   No mandatory Festapp/Mendelio writer migration is part of this revised scope.
3. Apply service `migrations/001_authority.sql` then `002_rpc.sql` once under the
   migration authority. Configure real application/customer/issuer/accounts and
   registered credentials under that authority. Gateway gets dispatch only, no
   domain table grants; executor remains NOLOGIN and tenant RLS applies.
4. Deploy the service in simulation with private R2 and dedicated feedback bindings.
   Verify marked fixture issue/PDF/QR, receipt loss/retry, bank facts and per-recipient
   feedback against the deployed runtime, using authorized test identities only.
5. Pause new CatalogPilot financial dispatch during transition. Apply additive
   `backend/migrations/083_invoicing_cutover.sql`, deploy CatalogPilot adapter and
   configure trusted mappings. Existing reservations settle under the commercial
   ledger; unsettled periods cannot close. Snapshot/outbox retry recovers a lost
   service response without duplicate numbering. Historical invoice/delivery tables
   become a read-only archive, not a fallback issuer.
6. Register the invoicing consumer/subscription in the existing BankSync only after
   callback verification and declared activation boundary. Start with new facts;
   preactivation replay requires a separate audit and authorization. Verify health
   and polling independently; unavailable facts produce verification_pending.
7. Under explicit live authorization, set live application/environment and
   `LIVE_ACTIVATION=verified-configuration`, enable the CatalogPilot mapping after
   initial authoritative status, and resume billing-gated dispatch. Confirm automatic
   customer delivery with owner copy using the confirmed delivery policy.

A service/provided reference is unique only within the service's permanent physical
account claims. Before live use, record how independently issued symbols on that
account are excluded or reconciled. Optional BankSync enrollment does not authorize
changes to another application's allocator. Requested-symbol rejection remains a
blocked incident with no fallback or number; correct the command explicitly.

## Operations and rollback

Monitor incidents API: blocked issuance, failed artifacts, unknown delivery,
terminal webhook and unmatched movement counts. Inspect committed app counters,
customer status freshness, next due boundary, import health and independent recipient
states. Never expose financial payloads/credentials in logs. Bound cron catch-up
and retry; monitor queues exceeding their batch limits. Reconcile unknown sends
against provider feedback before requesting an explicit resend with a fresh key.

Rollback pauses new issuance/email/dispatch, preserves invoices, permanent references,
allocations, inboxes, event counters, artifacts and pending deliveries, and restores a
compatible Worker. Never re-enable legacy writers, reuse symbols/numbers or resend
unknown messages automatically. Bank import and other consumers keep operating.
Restored BankSync reference registries remain locked until verified again.

## Removal/preservation ledger

| Path | Final local state |
|---|---|
| `monthly_close` | Commercial snapshot/command producer; service owns numbers |
| `monthly_invoices`, old `delivery_outbox` | Frozen legacy archive, write grants revoked |
| Owner invoice and automation routes | Service projections/commands; private PDF proxy |
| `admin/invoice/*.ts` | Removed; renderer/fonts owned by standalone service |
| AWS transport | One `packages/email-transport` source; recovery re-exports retained |
| Commercial pricing, provider budgets, recovery outbox | Preserved with targeted regression checks |
| Historical SQL/plans | Preserved; cutover is additive migration 083 |
| Existing BankSync imports/subscriptions | Preserved; optional registry and health API added |
| Festapp/Mendelio independent allocators | Unchanged by user's optional-VS clarification |

Legacy invoice details remain visible. Missing historical PDF artifacts must remain
an explicit gap; new PDFs always come from stored service artifacts.

## Executed production rollout - 2026-10-05

- InvoiceSync is deployed at `https://invoicesync.festapp.net`; authoritative RPC
  migrations and the additive CatalogPilot cutover are applied with backups.
  CatalogPilot's mapping is enabled after its initial authoritative status.
- InvoiceSync calls the existing BankSync exclusively through its public HTTPS API
  at `https://banksync-api.festapp.net`, using a dedicated tenant credential.
  There is no internal service binding. The existing Worker serves this custom
  domain and preserves its workers.dev endpoint for existing clients.
- BankSync runs package 0.2.7 and schema 12. Schema 11 was already present;
  its verified migration-ledger entry was repaired before applying additive 12.
  The isolated InvoiceSync consumer has its account grant and a subscription for
  new facts. Existing consumers and subscriptions were preserved.
- The permanent reference registry contains 4,754 historical exclusions without
  conflicts. New InvoiceSync references use ten digits; the live Mendelio allocator
  caps new references at nine digits. Legacy ten-digit references are imported.
  Live checks verified retry idempotency, historical collision rejection and
  rejection of another account. The marked probe reference remains reserved.
- The issuer, non-VAT regime, receiving account and owner were confirmed against
  Mendelio. CatalogPilot retains its existing simulation environment. Its buyer
  billing profile still requires completion through the normal application flow.
  No customer invoice or customer email was issued during rollout. Both legacy
  and service invoice inventories were empty at rollout.
- R2 public access is disabled and no custom bucket domain is configured. SES
  uses a dedicated InvoiceSync IAM principal restricted to its sender,
  configuration set and feedback queue. The exposed original AWS key was rotated
  across its known consumers and deleted. A marked SES simulator send succeeded;
  unrelated queue access, IAM management and an unapproved sender were denied.
- A real cron cycle fetched healthy bank status through HTTPS and delivered
  signed callbacks to CatalogPilot; its billing projection reports current status.
  The outbound webhook key map stores strings, while CatalogPilot's receiver
  `INVOICING_WEBHOOK_KEYS` stores `{ "v1": { "secret": "..." } }` records.
- Validation passed: eight disposable PostgreSQL tests, four actual workerd
  service tests and one independently built public-client test; BankSync
  composition typecheck, wrapper test and owning changed-file suite passed.

Registered application workload tokens expire on **2026-11-03T22:17:57Z**.
Rotate both client and worker credentials and their secret bindings before expiry.
Protected operational evidence and backups are retained outside Git.
