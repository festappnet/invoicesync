# InvoiceSync

PostgreSQL RPC owns financial state and authorization. Client code contains no
financial rules or Worker bindings. BankSync is the existing bank fact provider.
InvoiceSync owns reference allocation; BankSync supplies bank facts only.
Default reference mode is service. Historical banksync accounts require an explicit
local-history adoption receipt before local allocation; provided mode is explicit.
Never silently replace rejected references or retry unknown external delivery.
Use disposable PostgreSQL and actual workerd tests for finance/auth changes.
Deploy from verified main after backup; preserve permanent financial history.
Keep fixtures and secrets outside public artifacts. User authorization determines
production operations. Prefer verified direct publication to authoritative main.
