# InvoiceSync

PostgreSQL RPC owns financial state and authorization. Client code contains no
financial rules or Worker bindings. BankSync is the existing bank fact provider.
Default reference mode is BankSync; provided/service modes are explicit opt-ins.
Never silently replace rejected references or retry unknown external delivery.
Use disposable PostgreSQL and actual workerd tests for finance/auth changes.
Deploy from verified main after backup; preserve permanent financial history.
Keep fixtures and secrets outside public artifacts. User authorization determines
production operations. Prefer verified direct publication to authoritative main.
