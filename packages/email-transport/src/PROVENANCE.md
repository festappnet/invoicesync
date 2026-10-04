CatalogPilot follows Mendelio's transactional e-mail design: durable database
outbox, claim fencing, one SES transport, accepted receipts distinct from actual
delivery, and SES -> SNS -> SQS feedback. Sender uses the existing verified
mendelio.net identity with a CatalogPilot display name. Its configuration set,
topic and queue have separate catalogpilot names; Mendelio routes are unchanged.

AWS signing primitives in aws-sigv4.ts are adapted from the user's canonical
Mendelio source at roman_seznamka/supabase/functions/_shared/aws-sigv4.ts.
Provider calls are bounded TypeScript Worker code. Private credentials and reset
links never enter the frontend, public queue read or Git. Reset content uses
AES-GCM at rest, bound to kind, recipient and deduplication identity.

Recovery uses the same Supabase Auth operations as Mendelio: recover, a
single-use recovery token, and an authenticated password update. CatalogPilot
verifies the token with POST /verify only when submitting the new password;
the guarded Auth relay keeps Auth administration private. The link fragment is
removed from browser history before any request. This adapts Mendelio's flow
to CatalogPilot's existing HttpOnly application session instead of importing
Mendelio's browser SDK session or consuming tokens on an email-scanner GET.
