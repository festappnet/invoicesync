# InvoiceSync internal identity

InvoiceSync's `WORKLOADS_JSON` contains an independent database credential with
`read,jobs,bank` scopes. Renewing CatalogPilot's public client credential does
not renew this internal identity. The signer remains on the existing database
host; no signing key is installed in Cloudflare or on the workstation.

Install the verified `rotate_credentials.py` at
`/opt/invoicesync/ops/rotate_credentials.py`, and the matching service/timer in
`/etc/systemd/system`. Private root-owned mode-0600 state belongs under
`/opt/napojse/private/invoicesync-credential-rotation`:

- `state.json`: `{"workloads":[<complete existing WORKLOADS_JSON entry>]}`.
- `cloudflare-token.json`: `{"token":"<dedicated InvoiceSync Worker write token>"}`.
- `health.json`: last successful check time and expiry, without secret material.

The timer checks the actual authenticated database path every six hours, even
when no payments arrive. It renews a 30-day token seven days before expiry,
preserves the full binding, and retries failed runs after fifteen minutes.
Inspect both the unit and `health.json`; stale evidence is not a successful run.
Keep the publication token in encrypted credential storage as well as the
root-only operational working copy. Never retain a full-project database key.

```sh
systemctl status invoicesync-credential-rotation.timer invoicesync-credential-rotation.service
python3 /opt/invoicesync/ops/rotate_credentials.py --check
```

An expired predecessor needs explicit operator recovery with
`--recover-expired`. Recovery still requires its exact registered app, audience,
scope, expiry and unrevoked credential digest. It cannot revive a revoked or
broadened credential. State is persisted before registration/publication;
retries reuse the pending identity after uncertain responses.

## Delivery failures

An InvoiceSync webhook 401 can be a downstream database rejection. It does not
by itself prove a BankSync HMAC mismatch. Test the internal credential using
`--check`; `PGRST303 / JWT expired` identifies the transport JWT expiry. Invalid
bank signatures are separately rejected before database access.

After fixing the receiver, verify the exact delivery is absent from
`invoicing.bank_inbox` and replay only its stable ID through BankSync's audited
`POST /webhooks/replay`. Require the durable v2 receipt and recorded outcome;
do not delete terminal jobs or force-set them delivered. Confirm Monitoring's
BankSync delivery check recovers through fresh observations.

Regression check (requires psycopg and native PostgreSQL 17):

```sh
python -m unittest discover -s services/invoicing/tests -p 'test_credential_rotation.py' -q
```

## Workstation publication with existing OAuth

When a dedicated server publication token is unavailable, install
`net.festapp.invoicesync-credentials.plist` in the workstation's
`~/Library/LaunchAgents`. This runs `workstation_renewal.py` at login and every
six hours with the existing refreshable Wrangler OAuth login. The database
host still owns minting, exact-scope registration, pending state and checks.
Only the updated workload binding travels through a captured SSH pipe; the
signing key and Cloudflare OAuth credential remain on their respective machines.
An interrupted publication retains the same pending identity for retry.

This mode requires the workstation to be awake, logged in, and able to reach
SSH/Cloudflare within the seven-day renewal window. Its log is
`~/Library/Logs/invoicesync-credentials.log`; the host's `health.json` records
the last actual authenticated check. Keep the server timer disabled in this
mode. A dedicated server token can replace this mode by disabling the LaunchAgent,
installing the protected API token and enabling the server timer.

After signature verification, internal database 401/403 responses become HTTP
503 with the safe `bank_receiver_unavailable` code. The sender's own invalid
signature/account checks remain HTTP 403. Structured logs distinguish an
internal credential rejection without recording tokens or bank payloads.

The 2026-11-09 incident was one outgoing CZK 197 movement, delivery job 1035,
transaction 1183, consumer `invoicesync`. Its internal credential expired on
2026-11-03. BankSync polling and Festapp delivery continued independently.
Recovery renewed only the exact registered internal scope, replayed the stable
delivery ID through the audited endpoint, and obtained a durable receipt. The
outgoing movement created no invoice allocation. Monitoring's BankSync delivery
check recovered through fresh observations.
