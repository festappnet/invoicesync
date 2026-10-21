# InvoiceSync

Standalone invoicing Worker and public typed client. PostgreSQL RPC owns financial
state; private R2 stores immutable PDFs. BankSync provides payment facts. InvoiceSync owns permanent payment references
in PostgreSQL; caller-provided symbols remain an explicit account mode.

`@festapp/invoicesync` exports only the fetch/WebCrypto client; `/cloudflare` exports
the independent bundled Worker. Tests use disposable PostgreSQL without importing
any consumer application's schema.

```sh
pnpm install --frozen-lockfile
pnpm run typecheck
pnpm run build
pnpm test
uv run --with 'psycopg[binary]' python -m unittest discover -s services/invoicing/tests -p 'test_*.py' -q
uv run --with pymupdf --with zxing-cpp --with pillow python services/invoicing/tests/verify_pdf.py
```

[Contracts](services/invoicing/README.md) and [rollout](services/invoicing/ROLLOUT.md).

## JavaScript dependencies

Use pnpm 11.24.0, matching Mendelio and the other Festapp repositories. Run `pnpm install --frozen-lockfile` at the repository root, then `pnpm run <script>`. The root `pnpm-lock.yaml` and `pnpm-workspace.yaml` own dependency resolution and approved build scripts. Package content shares the user pnpm store; do not install with npm, commit npm lockfiles or copy `node_modules` between worktrees.
