# Shared invoicing service

Independent Cloudflare Worker, PostgreSQL RPC authority and private R2 artifacts.
The public consumer package is `packages/invoicing-client`; it needs only fetch and
WebCrypto. Application pricing, commercial settlement and product permissions
remain in the consuming application. Bank facts come from the existing BankSync.

## Local checks

From this standalone repository, use the root README checks with Node 24,
PostgreSQL binaries and psycopg. The commands below describe the original
CatalogPilot integration test run, retained as migration provenance:

```sh
npm ci --prefix packages/invoicing-client
npm ci --prefix services/invoicing
npm run build --prefix packages/invoicing-client
node --test packages/invoicing-client/tests/*.test.mjs
npm run typecheck --prefix services/invoicing
npm run build --prefix services/invoicing
PYTHONPATH=backend:backend/tests uv run --with 'psycopg[binary]' python -m unittest discover -s services/invoicing/tests -p 'test_*.py' -q
PYTHONPATH=backend:backend/tests uv run --with 'psycopg[binary]' python -m unittest test_invoicing_cutover test_email_queue test_automation test_finance_report -q
npm test --prefix services/invoicing
uv run --with pymupdf --with zxing-cpp --with pillow python services/invoicing/tests/verify_pdf.py
```

Tests use disposable PostgreSQL, transactional SQLite, actual workerd PDF rendering,
marked external fixtures, fake private storage and signed callbacks. They do not
contact banks, customers or SES. Set `INVOICING_TEST_PYTHON=1` when psycopg is already
installed; otherwise the integration bridge uses uv. `TEST_PG_BIN` selects PostgreSQL
binaries. The independently built public client test imports no CatalogPilot code.

## Contracts and invariants

HTTPS bearer endpoints: `POST /invoices`, `GET /invoices/:id`, authenticated private
`GET /invoices/:id/pdf`, `POST /invoices/:id/deliver`, customer profile GET/PUT,
`GET /customers/:id/billing-status`, `GET /events?cursor=...`, authenticated
`GET /company-lookup?country=CZ&ico=...`, schedule POST/PATCH and incidents GET.
Invoice, resend and schedule commands require an Idempotency-Key. Money is integer
minor-unit strings, quantities positive integers, CZK and non-VAT issuer only.
Profile writes and schedule changes carry their expected version. User-editable
profiles cannot set issuer identity, account or tenant mapping.

An accepted command is durable before numbering. Layout preflight and account
reference validation precede the immutable issued snapshot and number. PDF bytes
are hashed after private storage upload and checked again on download and send.
Payment, artifact and delivery state remain separate. Delivery intents carry
recipient role, artifact hash, lease and fence. Expired sending becomes unknown;
unknown never automatically resends. Accepted SES is not delivered. Feedback is
applied independently per recipient, with bounce/complaint suppression. If customer
and owner share an address, one intent covers the same document/address.

The explicit account mode `service` allocates permanent references in the service's
PostgreSQL registry. `provided` requires a caller's symbol; `banksync` is the default and
reserves a generated or requested `variable_symbol` through existing BankSync.
Modes are server configuration, with no fallback. BankSync may reject a requested
symbol with `reference_conflict` (409). The command stays blocked without a number
or replacement symbol, exposes that incident and requires a corrected new command.
Permanent claims are never reused. BankSync registry uniqueness covers its enrolled
and imported references; independent writers are outside that guarantee. Activating
any shared account therefore requires evidence for the chosen symbol namespace.

Webhook signature covers timestamp, delivery ID and original body bytes. The public
verifier supports bounded key rotation; recipients persist their inbox receipt and
projection atomically before acknowledging. Service events use an app counter locked
through commit, bounded polling batches and a high-water cursor. Invoice events omit the document snapshot; authenticated invoice reads supply it.
Customer summaries list the oldest 100 overdue invoices while totals cover all debts.
Retention currently keeps all events. Polling and authoritative customer status recover missing callbacks.
Bank v2 callbacks also verify pairing code, account, instance and consumer mapping.
Only identified incoming FIO movements can allocate money; observations, ambiguity,
wrong currency, preactivation facts and unmatched money require reconciliation.
Manual reconciliation needs an explicit credential scope and an audit reason.
Overpayment remains unallocated; it never automatically pays a different invoice.

ARES uses the official fixed REST endpoint, preserves eight-digit IDs, validates
identity, bounds body/time, uses positive/stale cache and distinguishes a 404 from
an unavailable provider. Registry proposals require explicit acceptance in the UI;
customer email and manual tax ID are not invented or overwritten.

## Rollout

See [the concrete rollout manifest](ROLLOUT.md). Production deployment and verification evidence are recorded there.
Production configuration uses secret bindings; no credentials are stored in Git.
CatalogPilot can switch its application to live billing after migration 004.
Frozen simulation invoices remain visible but are excluded from live debt,
overdue events and bank-payment matching; automatic simulation mail stays suppressed.

Customer profiles can set `language` to `cs` or `en` (default `cs`). The immutable
buyer profile determines PDF and email language. Invoice lines may provide
`description_en`; the application owns both descriptions. App-scoped branding
supplies the sender display name, canonical vector logo and inline email PNG.
Simulation emails explicitly say not to pay. Automatic simulation delivery
remains suppressed; an operator may queue one audited owner-authorized test.
Feedback drains up to three batches of ten messages per scheduled invocation so
old validation/preview messages do not prevent delivery events being processed.
