# InvoiceSync

Standalone invoicing Worker and public typed client. PostgreSQL RPC owns financial
state; private R2 stores immutable PDFs. BankSync provides payment facts. InvoiceSync owns permanent payment references
in PostgreSQL; caller-provided symbols remain an explicit account mode.

`@festapp/invoicesync` exports only the fetch/WebCrypto client; `/cloudflare` exports
the independent bundled Worker. Tests use disposable PostgreSQL without importing
any consumer application's schema.

```sh
npm ci
npm run typecheck
npm run build
npm test
uv run --with 'psycopg[binary]' python -m unittest discover -s services/invoicing/tests -p 'test_*.py' -q
uv run --with pymupdf --with zxing-cpp --with pillow python services/invoicing/tests/verify_pdf.py
```

[Contracts](services/invoicing/README.md) and [rollout](services/invoicing/ROLLOUT.md).
