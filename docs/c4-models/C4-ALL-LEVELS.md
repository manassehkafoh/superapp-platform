# C4 Model — SuperApp Platform
> All four C4 levels: Context → Container → Component → Code

---

## C1 — SYSTEM CONTEXT DIAGRAM

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║                         SUPERAPP — SYSTEM CONTEXT (C1)                          ║
╚══════════════════════════════════════════════════════════════════════════════════╝

  PEOPLE / ACTORS                    SUPERAPP PLATFORM            EXTERNAL SYSTEMS
  ──────────────                     ─────────────────            ────────────────
  
  ┌──────────────┐   HTTPS/REST   ┌─────────────────────────┐
  │  Retail      │ ─────────────► │                         │ ────────────────────►  ┌──────────────┐
  │  Customer    │                │                         │   ISO 8583 / REST       │  T24 Core    │
  │  (Mobile/Web)│ ◄───────────── │    SUPERAPP PLATFORM    │                         │  Banking     │
  └──────────────┘   Push/WS      │                         │                         └──────────────┘
                                  │  Financial super-app    │
  ┌──────────────┐   HTTPS/REST   │  providing: payments,   │ ────────────────────►  ┌──────────────┐
  │  SME         │ ─────────────► │  wallets, accounts,     │   GhIPSS Protocol       │  GhIPSS      │
  │  Business    │                │  identity & notifs      │                         │  (National   │
  │  Customer    │ ◄───────────── │                         │                         │   Switch)    │
  └──────────────┘                │                         │ ────────────────────►  └──────────────┘
                                  │                         │
  ┌──────────────┐   HTTPS/Portal │                         │   REST/OAuth2           ┌──────────────┐
  │  Bank Admin  │ ─────────────► │                         │ ────────────────────►   │  ExpressPay  │
  │  (Staff)     │                │                         │                         │  (Mobile     │
  └──────────────┘                │                         │                         │   Money GW)  │
                                  │                         │ ────────────────────►  └──────────────┘
  ┌──────────────┐   SSH/VPN      │                         │   REST/SOAP
  │  DevOps      │ ─────────────► │                         │                         ┌──────────────┐
  │  Engineer    │                │                         │ ────────────────────►   │  Hubtel      │
  └──────────────┘                │                         │   REST API              │  (SMS/Voice) │
                                  │                         │                         └──────────────┘
  ┌──────────────┐   Azure AD SSO │                         │
  │  Security    │ ─────────────► │                         │   ACH/ISO 20022         ┌──────────────┐
  │  Analyst     │                │                         │ ────────────────────►   │  ACH Network │
  └──────────────┘                └─────────────────────────┘                         └──────────────┘
                                                                SMTP/SendGrid          ┌──────────────┐
                                                               ────────────────────►   │  Email (SG)  │
                                                                                        └──────────────┘
                                                                SMPP/HTTP              ┌──────────────┐
                                                               ────────────────────►   │  SMS Gateway │
                                                                                        └──────────────┘
```

---

## C2 — CONTAINER DIAGRAM

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║                       SUPERAPP — CONTAINER DIAGRAM (C2)                          ║
╚══════════════════════════════════════════════════════════════════════════════════╝

CLIENT TIER
──────────
  ┌─────────────────────┐    ┌─────────────────────┐
  │   Mobile App        │    │   Web SPA            │
  │   [React Native]    │    │   [React/Next.js]    │
  │   iOS + Android     │    │   Browser            │
  └──────────┬──────────┘    └──────────┬───────────┘
             │                          │
             └──────────────┬───────────┘
                    HTTPS/TLS 1.3 + mTLS
                            │
EDGE LAYER                  │
──────────                  ▼
             ┌──────────────────────────────┐
             │   Cloudflare CDN / WAF        │
             │   [DDoS, Bot, Rate Limit]     │
             └──────────────┬───────────────┘
                            │
             ┌──────────────▼───────────────┐
             │   Azure Front Door            │
             │   [Global LB, GeoDNS, WAF]   │
             └──────────────┬───────────────┘
                            │
PERIMETER                   │
─────────                   ▼
             ┌──────────────────────────────┐
             │   Azure Firewall Premium      │
             │   [L7 IDPS, TLS Inspection]  │
             └──────────────┬───────────────┘
                            │
KUBERNETES CLUSTER (AKS — Azure) ◄──GitOps (ArgoCD)──► GitHub/GitLab
─────────────────────────────────
                            │
             ┌──────────────▼───────────────┐
             │   NGINX Ingress Controller    │
             │   [TLS termination, routing] │
             └──────────────┬───────────────┘
                            │
             ┌──────────────▼───────────────────────────────────────────┐
             │              API GATEWAY LAYER                            │
             │  ┌──────────────────────────────────────────────────┐    │
             │  │  YARP + Ocelot Gateway [ASP.NET 8]               │    │
             │  │  • JWT validation (RS256, JWKS endpoint)         │    │
             │  │  • Rate limiting (per user/IP/tenant)            │    │
             │  │  • CORS enforcement                              │    │
             │  │  • Correlation-ID injection + propagation        │    │
             │  │  • Request/Response logging (structured)         │    │
             │  │  • Circuit breaker (Polly)                       │    │
             │  │  • OpenTelemetry trace propagation               │    │
             │  │  Port: 8080 (HTTP) / 8443 (HTTPS)               │    │
             │  └──────────────────────────────────────────────────┘    │
             └──────────────────────────┬────────────────────────────────┘
                                        │
             ┌──────────────────────────▼────────────────────────────────┐
             │              MICROSERVICES LAYER                           │
             │  (All services in separate namespaces, mTLS via Cilium)   │
             │                                                            │
             │  ┌───────────────────┐   ┌───────────────────────┐       │
             │  │  Identity API      │   │  Account API           │       │
             │  │  [ASP.NET 8]      │   │  [ASP.NET 8]          │       │
             │  │  ns: identity      │   │  ns: accounts         │       │
             │  │  • JWT issuance    │   │  • Bank links         │       │
             │  │  • MFA/TOTP        │   │  • Investment links   │       │
             │  │  • User lifecycle  │   │  • Pension links      │       │
             │  │  • RBAC mgmt      │   │  • Payment sources    │       │
             │  └─────────┬─────────┘   └──────────┬────────────┘       │
             │            │ Events                   │ Events            │
             │  ┌─────────▼─────────┐   ┌──────────▼────────────┐       │
             │  │  Payment API       │   │  WalletSystem API      │       │
             │  │  [ASP.NET 8]      │   │  [ASP.NET 8]          │       │
             │  │  ns: payments      │   │  ns: wallet           │       │
             │  │  • GhIPSS flows   │   │  • Double-entry ledger│       │
             │  │  • ACH transfers  │   │  • Wallet CRUD        │       │
             │  │  • Bill payments  │   │  • Balance enquiry    │       │
             │  │  • Fund transfers │   │  • Transaction history│       │
             │  │  • Saga orchestr. │   │  • Reconciliation     │       │
             │  └─────────┬─────────┘   └──────────┬────────────┘       │
             │            │ Events                   │                   │
             │  ┌─────────▼────────────────────────────────────────┐    │
             │  │  Logging & Notification API [ASP.NET 8]          │    │
             │  │  ns: notifications                                │    │
             │  │  • Kafka consumer (all domains)                   │    │
             │  │  • Push notifications (Firebase/APNs)            │    │
             │  │  • SMS via Hubtel / Twilio                       │    │
             │  │  • Email via SendGrid                            │    │
             │  │  • Audit log writer (immutable)                  │    │
             │  └──────────────────────────────────────────────────┘    │
             │                                                            │
             │  ┌──────────────────────────────────────────────────┐    │
             │  │  APIHive (OpenAPI Aggregator) [Kong/Nginx]        │    │
             │  │  • Aggregated Swagger UI                          │    │
             │  │  • API key management                             │    │
             │  │  • Developer portal                              │    │
             │  └──────────────────────────────────────────────────┘    │
             └──────────────────────────┬────────────────────────────────┘
                                        │
             ┌──────────────────────────▼────────────────────────────────┐
             │              INFRASTRUCTURE SERVICES LAYER                 │
             │                                                            │
             │  ┌──────────────┐  ┌────────────┐  ┌───────────────────┐ │
             │  │ Apache Kafka │  │   Redis     │  │  HashiCorp Vault  │ │
             │  │ (Strimzi)    │  │  Cluster   │  │  (HA, Raft)       │ │
             │  │ 3 brokers    │  │  3 nodes   │  │  Secret mgmt      │ │
             │  └──────────────┘  └────────────┘  └───────────────────┘ │
             │                                                            │
             │  ┌──────────────┐  ┌────────────┐  ┌───────────────────┐ │
             │  │ SPIRE Server │  │  OPA/Gateky │  │  Falco + Tetragon│ │
             │  │ (SPIFFE ID)  │  │  (Policies) │  │  (Runtime Sec)   │ │
             │  └──────────────┘  └────────────┘  └───────────────────┘ │
             └──────────────────────────┬────────────────────────────────┘
                                        │
             ┌──────────────────────────▼────────────────────────────────┐
             │                    DATA TIER                               │
             │                                                            │
             │  ┌──────────────────┐   ┌──────────────────────────────┐  │
             │  │  Azure SQL (PRI)  │   │  Azure SQL (GEO-SECONDARY)   │  │
             │  │  • identity_db    │   │  (Read replicas, DR)         │  │
             │  │  • account_db     │   └──────────────────────────────┘  │
             │  │  • payment_db     │                                      │
             │  │  • wallet_db      │   ┌──────────────────────────────┐  │
             │  │  • notification_db│   │  Azure Data Lake (Audit)     │  │
             │  └──────────────────┘   │  Immutable, WORM policy       │  │
             │                          └──────────────────────────────┘  │
             └──────────────────────────┬────────────────────────────────┘
                                        │
             ┌──────────────────────────▼────────────────────────────────┐
             │              INTEGRATION LAYER (ESB/Adapters)             │
             │                                                            │
             │  ┌──────────────────┐   ┌──────────────────────────────┐  │
             │  │  T24 Adapter     │   │  Payment Rail Adapters       │  │
             │  │  [MassTransit]   │   │  • GhIPSS Adapter            │  │
             │  │  REST + IRIS API │   │  • ExpressPay Adapter        │  │
             │  └──────────────────┘   │  • ACH Adapter               │  │
             │                          │  • Hubtel Adapter            │  │
             │                          │  • ITC Adapter               │  │
             │                          └──────────────────────────────┘  │
             └───────────────────────────────────────────────────────────┘

             OBSERVABILITY STACK (cross-cutting)
             ────────────────────────────────────
             OpenTelemetry Collector → Tempo (Traces) + Loki (Logs) + Prometheus (Metrics)
             Grafana Dashboards → PagerDuty Alerts → Slack/Teams
```

---

## C3 — COMPONENT DIAGRAM (Payment API)

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║                PAYMENT API — COMPONENT DIAGRAM (C3)                              ║
╚══════════════════════════════════════════════════════════════════════════════════╝

  [API Gateway] ──HTTPS/mTLS──► [Payment API: ASP.NET 8 — namespace: payments]
                                 │
                    ┌────────────┼────────────────────────────────────┐
                    │            │                                     │
           ┌────────▼────┐  ┌───▼────────────┐  ┌────────────────────▼──────┐
           │  Controllers│  │  Middleware     │  │  Background Services       │
           │  ─────────── │  │  ─────────────  │  │  ──────────────────────── │
           │ PaymentCtrl  │  │ JwtValidation  │  │  OutboxWorker              │
           │ TransferCtrl │  │ RateLimiting   │  │  (polls outbox, publishes  │
           │ BillPayCtrl  │  │ Correlation    │  │   events to Kafka)         │
           │ StatusCtrl   │  │ OpenTelemetry  │  │  SagaStateMachine          │
           └──────┬───────┘  │ ExceptionMW    │  │  (MassTransit Saga)        │
                  │           └────────────────┘  └─────────────────┬──────────┘
                  │                                                   │
         ┌────────▼──────────────────────────────────────────────────▼─────┐
         │                    APPLICATION LAYER                              │
         │  ┌─────────────────────────┐  ┌─────────────────────────────┐   │
         │  │  PaymentApplicationSvc  │  │  TransferApplicationSvc     │   │
         │  │  • InitiatePayment()    │  │  • InitiateFundTransfer()   │   │
         │  │  • GetPaymentStatus()   │  │  • ValidateTransferLimits() │   │
         │  │  • CancelPayment()      │  │  • GetTransferHistory()     │   │
         │  └────────────┬────────────┘  └──────────────┬──────────────┘   │
         │               │                               │                  │
         └───────────────┼───────────────────────────────┼──────────────────┘
                         │                               │
         ┌───────────────▼───────────────────────────────▼──────────────────┐
         │                    DOMAIN LAYER (DDD)                              │
         │  ┌─────────────────┐  ┌──────────────┐  ┌──────────────────────┐ │
         │  │  Payment        │  │  Saga        │  │  Domain Events        │ │
         │  │  Aggregate Root │  │  Definitions │  │  PaymentInitiated     │ │
         │  │  • PaymentId    │  │  PaymentSaga │  │  PaymentCompleted     │ │
         │  │  • Amount       │  │  TransferSaga│  │  PaymentFailed        │ │
         │  │  • Status       │  │              │  │  FundsDebited         │ │
         │  │  • IdempotencyKey│ │              │  │  FundsCredited        │ │
         │  └────────────┬────┘  └──────────────┘  └──────────────────────┘ │
         └───────────────┼────────────────────────────────────────────────────┘
                         │
         ┌───────────────▼────────────────────────────────────────────────────┐
         │                 INFRASTRUCTURE LAYER                                │
         │  ┌──────────────────────┐   ┌───────────────────────────────────┐  │
         │  │  Repositories        │   │  External Adapters                │  │
         │  │  ─────────────────── │   │  ──────────────────────────────── │  │
         │  │  PaymentRepository   │   │  GhIPSSAdapter (REST)             │  │
         │  │  OutboxRepository    │   │  ExpressPayAdapter (REST/OAuth2)  │  │
         │  │  IdempotencyStore    │   │  ACHAdapter (ISO 20022)           │  │
         │  │   (Redis)            │   │  T24Adapter (IRIS API)            │  │
         │  └──────────────────────┘   │  WalletGrpcClient                 │  │
         │                             │  NotificationEventPublisher       │  │
         │  ┌──────────────────────┐   └───────────────────────────────────┘  │
         │  │  Kafka Producer      │                                           │
         │  │  • PublishEvent()    │   ┌───────────────────────────────────┐  │
         │  │  • PublishSaga()     │   │  Vault SecretProvider             │  │
         │  └──────────────────────┘   │  (DB conn strings, API keys)      │  │
         └──────────────────────────── └───────────────────────────────────┘  │
                                        └──────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  KAFKA TOPICS PUBLISHED BY PAYMENT API:                                     │
  │  • superapp.payment.v1.payment-initiated  (after DB write + Outbox commit) │
  │  • superapp.payment.v1.payment-completed  (on downstream success response)  │
  │  • superapp.payment.v1.payment-failed     (on error/timeout/rejection)     │
  │  • superapp.payment.v1.payment-cancelled  (on explicit cancellation)       │
  │                                                                             │
  │  KAFKA TOPICS CONSUMED BY PAYMENT API:                                      │
  │  • superapp.wallet.v1.funds-debited       (saga continuation)               │
  │  • superapp.identity.v1.account-verified  (KYC check completion)           │
  └─────────────────────────────────────────────────────────────────────────────┘
```

---

## C3 — COMPONENT DIAGRAM (Identity API)

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║                IDENTITY API — COMPONENT DIAGRAM (C3)                             ║
╚══════════════════════════════════════════════════════════════════════════════════╝

  [API Gateway] ──HTTPS/mTLS──► [Identity API: ASP.NET 8 — namespace: identity]

  Components:
  ┌───────────────────────────────────────────────────────────────────────────────┐
  │  CONTROLLERS                                                                   │
  │  AuthController      POST /auth/login, POST /auth/refresh, POST /auth/logout  │
  │  UserController      CRUD /users, GET /users/{id}, PATCH /users/{id}          │
  │  MfaController       POST /mfa/enroll, POST /mfa/verify                       │
  │  PasswordController  POST /password/reset, POST /password/change              │
  └────────────────────────────────────────────────────────┬──────────────────────┘
                                                           │
  ┌────────────────────────────────────────────────────────▼──────────────────────┐
  │  DOMAIN SERVICES                                                               │
  │  TokenService        Issue JWT (RS256), refresh tokens, revocation            │
  │  UserService         User lifecycle, profile management                       │
  │  MfaService          TOTP (RFC 6238), SMS OTP via Hubtel                     │
  │  KycService          Identity document verification via third-party           │
  │  PasswordService     Bcrypt hashing, complexity enforcement, history check    │
  │  AuditService        All auth events → Kafka → Immutable audit log           │
  └────────────────────────────────────────────────────────┬──────────────────────┘
                                                           │
  ┌────────────────────────────────────────────────────────▼──────────────────────┐
  │  INFRASTRUCTURE                                                                │
  │  UserRepository      EF Core + Azure SQL (identity_db)                        │
  │  TokenBlacklist      Redis (revoked token JTIs, 24h TTL)                      │
  │  JwksEndpoint        Expose public key for downstream JWT validation           │
  │  KafkaProducer       Publish identity events                                   │
  │  VaultClient         Retrieve JWT signing key from Vault                       │
  └───────────────────────────────────────────────────────────────────────────────┘

  JWT TOKEN SPECIFICATION:
  ┌───────────────────────────────────┐
  │  Header: { alg: RS256, kid: ... } │
  │  Payload:                         │
  │    sub: <userId>                  │
  │    email: <email>                 │
  │    roles: [customer, sme_admin]   │
  │    tenant: <tenantId>             │
  │    jti: <uniqueTokenId>           │
  │    iat: <issuedAt>                │
  │    exp: <expiresAt: +15min>       │
  │    amr: [pwd, totp]               │
  │  Signed with: RSA 4096 private key│
  │  Stored in: Vault (auto-rotated)  │
  └───────────────────────────────────┘
```

---

## C3 — COMPONENT DIAGRAM (Wallet System API)

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║               WALLET SYSTEM API — COMPONENT DIAGRAM (C3)                         ║
╚══════════════════════════════════════════════════════════════════════════════════╝

  Components:
  ┌───────────────────────────────────────────────────────────────────────────────┐
  │  CONTROLLERS                                                                   │
  │  WalletController      GET /wallets/{id}, POST /wallets                       │
  │  BalanceController     GET /wallets/{id}/balance                               │
  │  TransactionController GET /wallets/{id}/transactions, POST /debit, POST /credit│
  │  ReconcileController   POST /wallets/reconcile (internal only)                 │
  └────────────────────────────────────────────────────────┬──────────────────────┘
                                                           │
  ┌────────────────────────────────────────────────────────▼──────────────────────┐
  │  DOMAIN — DOUBLE-ENTRY LEDGER                                                  │
  │                                                                                │
  │  Every financial movement creates TWO ledger entries (double-entry):           │
  │                                                                                │
  │  DEBIT ENTRY          CREDIT ENTRY                                             │
  │  ─────────────        ─────────────                                            │
  │  account_id: wallet   account_id: cash_pool                                    │
  │  amount: -100.00      amount: +100.00                                          │
  │  currency: GHS        currency: GHS                                            │
  │  entry_type: DEBIT    entry_type: CREDIT                                       │
  │  tx_ref: uuid         tx_ref: uuid (same)                                      │
  │  idempotency_key:...  idempotency_key:... (same)                               │
  │                                                                                │
  │  Invariant: SUM(all entries) MUST = 0 at all times                            │
  │  Verified by: ReconciliationJob (every 15 min, alert on mismatch)             │
  └───────────────────────────────────────────────────────────────────────────────┘
```

---

## C4 — CODE DIAGRAM (Payment Saga)

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║                   PAYMENT SAGA — CODE LEVEL (C4)                                 ║
╚══════════════════════════════════════════════════════════════════════════════════╝

  CLASS: PaymentSaga (MassTransit StateMachine)
  ────────────────────────────────────────────
  
  States: Initial → Pending → Debiting → Processing → Completed
                              ↓           ↓
                           Failed ←─── Timeout
  
  STEP 1: PaymentInitiated event received
    → Validate idempotency key (check Redis)
    → Set state = Debiting
    → Publish: DebitWalletCommand → wallet-svc
    → Set saga timeout = 30s
  
  STEP 2: WalletDebited event received
    → Set state = Processing
    → Call payment rail (GhIPSS/ACH) via adapter
    → Publish: PaymentSubmittedToRail
  
  STEP 3a: PaymentRailConfirmed
    → Set state = Completed
    → Publish: PaymentCompleted (for notification-svc)
    → Publish: LedgerEntryCommand → wallet-svc (finalize)
  
  STEP 3b: PaymentRailFailed / Timeout
    → Set state = Failed
    → Publish: CompensateDebitCommand → wallet-svc (rollback)
    → Publish: PaymentFailed (for notification-svc)
    → Increment failure metric
  
  COMPENSATING TRANSACTIONS:
  If any step fails, reverse previous steps in LIFO order:
    CompensateDebitCommand → reverses wallet debit
    This ensures no funds lost even on partial failure

  IDEMPOTENCY:
  Every saga instance keyed on: idempotency_key (client-provided UUID)
  Duplicate requests return existing saga state (no double processing)
```
