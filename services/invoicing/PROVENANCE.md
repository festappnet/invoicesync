# Renderer provenance

`render.ts`, `types.ts`, `format.ts`, `fonts.ts` copied from the user's Mendelio Voice
`/Users/miakh/source/roman_seznamka/packages/billing/src/invoice/` on 2026-10-03.
Source project was not modified. Embedded DejaVu fonts retain their upstream license
and source details in the original `fonts.ts` header.

Adaptation: monthly immutable commercial ledger snapshots replace paid orders;
PDFs have multi-page shop/action line items, a billing period, and simulation
marking. No paid-order RPC is reused and no paid stamp is emitted for unpaid usage.
Unconfigured legal parties block real rendering. No mail provider is connected.

The existing provider reservation/checkpoint/settlement ledger follows Mendelio's
paid operations pattern. Commercial prices/reservations stay separate. The initial
v1 ledger was kept and extended with incremental migrations.
