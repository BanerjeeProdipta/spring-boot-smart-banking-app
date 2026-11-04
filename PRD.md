# Smart Banking App — Product Requirements Document

Version 2.0 · Prepared for Prodipta Banerjee · Status: Draft for build

## 1. Overview

Smart Banking App is a simulated retail-bank backend. It covers customer onboarding, account management, deposits, withdrawals, transfers, transaction history, and event-driven notifications with basic fraud flagging. No real money moves and no card or payment data is handled, so there is no PCI scope.

The project is a portfolio piece. Its secondary purpose is to demonstrate, in one coherent system, the engineering practices that Canadian bank and fintech teams look for: Java and Spring Boot, relational data modelling, safe money handling under concurrency, REST API design, event-driven messaging, security, automated testing, containers, and CI/CD.

### 1.1 Goals

1. Money is always correct: no lost, duplicated, or invented funds, including under concurrent and retried requests.
2. Every behaviour is covered by an explicit acceptance criterion and an automated test.
3. The system can be run locally with a single command and is reachable as a live deployment with interactive API docs.
4. The design choices are defensible in an interview: every non-obvious decision in this document has a stated reason.

### 1.2 Non-goals

- Real payment rails, card processing, PCI-DSS compliance, real KYC or AML integrations.
- Mobile app, multi-currency, interest calculation, loans, statements as PDFs.
- Production-grade multi-region high availability.

## 2. Users and Roles

| Role | Description | Key capabilities |
| --- | --- | --- |
| Customer | A retail banking customer | Open accounts, view own balances, deposit, withdraw, transfer, view own history |
| Admin | A bank operations employee | View and manage customers, freeze or unfreeze accounts, review and resolve flagged transactions |
| System | Internal services | Publish and consume transaction events, apply fraud rules, send notifications |

A Customer may only ever access their own accounts and transactions. This ownership rule is a hard requirement, not a nicety (see Security).

## 3. Domain Model

### 3.1 Entities

**Customer**: id, name, email (unique), KYC status (PENDING, VERIFIED, REJECTED), created at.

**Account**: id, customer id, type (CHECKING or SAVINGS), balance, currency (CAD only in v1, stored explicitly so multi-currency is a later extension rather than a migration), status (ACTIVE, FROZEN, CLOSED), version (for optimistic locking), created at.

**Transaction (ledger entry)**: id, account id, counterparty account id (nullable), transfer id (nullable), type (DEPOSIT, WITHDRAWAL, TRANSFER\_OUT, TRANSFER\_IN), amount, status (COMPLETED, FLAGGED, FAILED), created at.

**Outbox event**: id, aggregate id, event type, payload, created at, published at (null until relayed). Introduced in Phase 3.

**Notification**: id, transaction id, channel (log or email stub), message, created at. Owned by the notification service.

**Fraud review**: id, transaction id, rule that fired, status (OPEN, CLEARED, CONFIRMED), reviewed by, reviewed at.

### 3.2 Ledger model

A transfer is recorded as two ledger entries, one TRANSFER\_OUT on the source account and one TRANSFER\_IN on the destination, linked by a shared transfer id. Deposits and withdrawals are a single entry each. The ledger is append-only: entries are never updated except for the status field moving from COMPLETED to FLAGGED. Account balance is a stored value that must always equal opening balance plus the sum of its ledger entries; a reconciliation test asserts this.

### 3.3 Invariants

- Amount is strictly positive and has at most two decimal places.
- Balance is never negative (enforced in domain logic and by a database check constraint).
- A transfer's source and destination accounts must differ.
- Only ACTIVE accounts can be debited or credited. FROZEN and CLOSED accounts reject all movements.
- All money values use exact decimal arithmetic. Floating point is prohibited anywhere money is computed, stored, or serialized.

## 4. Architecture

### 4.1 Evolution

The system begins as a single Spring Boot monolith talking to PostgreSQL. It is split into two services in Phase 3, when asynchronous messaging is introduced.

### 4.2 Target state

**banking-core-service** owns customers, accounts, the ledger, authentication, and the admin review workflow. It owns the primary PostgreSQL database and the outbox table.

**notification-service** consumes transaction events, applies fraud rules, records notifications, and emits flag events. It owns its own small database (notification log, processed-event log). It never reads or writes the core database.

**Apache Kafka** carries two topics: transaction-created (core to notification) and transaction-flagged (notification back to core). Messages are keyed by account id so events for one account stay ordered.

**Redis** (optional, Phase 4) caches balance reads for display only.

&#91;embedded content: target architecture · 2 services, 2 topics, 1 sync call\]

Events flow from the core service through the outbox relay and Kafka to the notification service, and flags return on a second topic. The one synchronous call is the notification service's contact lookup, protected by a circuit breaker.

### 4.3 Data ownership rule

Each service owns its data. Services communicate only through events or through the other service's public API. The notification service flags a transaction by publishing an event that the core service consumes and applies; it does not write to the core database.

### 4.4 Reliable event publication

Publishing to Kafka directly from a request handler creates a dual-write problem: the database commit can succeed while the publish fails, or the reverse. The core service therefore uses a transactional outbox. The business change and the outbox row are written in the same database transaction. A background relay reads unpublished outbox rows, publishes them to Kafka, and marks them published. Delivery is at-least-once, so consumers must be idempotent: the notification service records each processed event id and ignores duplicates.

## 5. Functional Requirements

Requirement ids use the form FR-phase.number so tests and commits can reference them.

### Phase 1: Core monolith (MVP)

| Id | Requirement | Acceptance criteria |
| --- | --- | --- |
| FR-1.1 | Customer management | Create, read, update customers. Duplicate email returns a conflict error. |
| FR-1.2 | Account management | Open a CHECKING or SAVINGS account for an existing customer with a zero or positive opening balance. Read an account. Admin can freeze, unfreeze, and close. Closing requires a zero balance. |
| FR-1.3 | Deposit | Credits an active account and records one DEPOSIT entry atomically. |
| FR-1.4 | Withdrawal | Debits an active account if funds suffice and records one WITHDRAWAL entry atomically. Insufficient funds is rejected with no state change. |
| FR-1.5 | Transfer | Debits the source and credits the destination in one database transaction and records two linked ledger entries. Any failure leaves both balances untouched. |
| FR-1.6 | Idempotent transfers | A transfer request carries an Idempotency-Key header. Repeating a request with the same key returns the original result and moves no additional money. Keys are unique per customer. |
| FR-1.7 | Concurrency safety | Concurrent requests touching the same account never lose or create money. Conflicts surface as a retryable conflict error. |
| FR-1.8 | Transaction history | Paginated, newest first, per account, with page and size parameters and an enforced maximum page size. |
| FR-1.9 | Validation and errors | All input is validated. All errors use one consistent response format with a machine-readable code (see section 6). No stack traces or internal details leak to clients. |
| FR-1.10 | API documentation | Every endpoint appears in generated OpenAPI documentation with request and response examples. |
| FR-1.11 | CI pipeline | Every push builds the project and runs all tests. The main branch stays green. |

### Phase 2: Security and authentication

| Id | Requirement | Acceptance criteria |
| --- | --- | --- |
| FR-2.1 | Registration and login | Passwords are stored only as strong salted hashes. Login returns a short-lived access token and a longer-lived refresh token. |
| FR-2.2 | Token lifecycle | Access tokens expire in about 15 minutes. Refresh tokens rotate on use, are stored hashed, and can be revoked. A reused refresh token invalidates its family. |
| FR-2.3 | Role-based access | Customer and Admin roles gate every endpoint. Unauthenticated requests receive 401 and unauthorized requests receive 403. |
| FR-2.4 | Ownership enforcement | A Customer requesting another customer's account, history, or transfer source receives a not-found response, not a forbidden one, so account existence is not disclosed. |
| FR-2.5 | Login rate limiting | Repeated failed logins for one username or one source address are throttled with a 429 response and a retry-after hint. |
| FR-2.6 | Audit trail | Security-relevant actions (login, failed login, freeze, review decision) are recorded with actor, time, and outcome. |

### Phase 3: Events and service split

| Id | Requirement | Acceptance criteria |
| --- | --- | --- |
| FR-3.1 | Outbox | Every ledger entry creation writes a TransactionCreated outbox row in the same transaction. A relay publishes pending rows and marks them published. A killed relay or broker outage loses no events. |
| FR-3.2 | Notification consumer | The notification service consumes TransactionCreated, records a notification (log or email stub), and ignores duplicate event ids. |
| FR-3.3 | Fraud rules | Rule 1: a single transaction above a configurable threshold (default CAD 10,000) is flagged. Rule 2: more than a configurable number of transfers from one account within a configurable window (default 5 within 10 minutes) is flagged. Thresholds are configuration, not code constants. |
| FR-3.4 | Flag feedback | A flagged transaction produces a TransactionFlagged event. The core service consumes it, marks the ledger entry FLAGGED, and opens a fraud review. |
| FR-3.5 | Admin review | Admin can list open reviews and mark each as CLEARED or CONFIRMED, with the decision audited. Flagging never blocks or reverses the original transaction in v1; it is a review signal. |
| FR-3.6 | Poison messages | A message that fails processing repeatedly is moved to a dead-letter topic after a bounded number of retries. |

### Phase 4: Resilience and observability

| Id | Requirement | Acceptance criteria |
| --- | --- | --- |
| FR-4.1 | Health and metrics | Both services expose health, readiness, and metrics endpoints. Health reflects database and broker connectivity. |
| FR-4.2 | Structured logging | Logs are JSON with a correlation id that propagates from the HTTP request through Kafka headers to the consumer. One id lets you trace a transaction across both services. |
| FR-4.3 | Synchronous dependency with circuit breaker | The notification service calls a core endpoint to look up the customer's contact details when building a notification. That call is protected by a circuit breaker with timeout, limited retries, and a fallback that records the notification without contact details. This is the one deliberate synchronous call, and it exists to make the circuit breaker meaningful. |
| FR-4.4 | Balance cache (optional) | Balance reads for display use a short-lived cache invalidated on every write to that account. Transfer, deposit, and withdrawal logic never read balances from the cache. If this cannot be made demonstrably correct, it is cut. |
| FR-4.5 | Key metrics | Counters and timers for transfers, failures by error code, optimistic-lock conflicts, outbox lag, and flagged transactions. |

### Phase 5: Deployment and delivery

| Id | Requirement | Acceptance criteria |
| --- | --- | --- |
| FR-5.1 | Containers | Each service has a container image. A single compose file starts the databases, broker, optional cache, and both services locally. |
| FR-5.2 | Pipeline | The pipeline builds, tests, checks coverage, builds images, and pushes them on main. |
| FR-5.3 | Cloud deployment | At least the core service is deployed to a free-tier host with a public documentation URL. Secrets come from environment configuration. |
| FR-5.4 | Seed data | A documented seed step creates demo customers, accounts, and an admin user so reviewers can try the API immediately. |

### Phase 6 (optional)

A minimal web frontend consuming the API, and local Kubernetes manifests. Only attempted once Phases 1 to 5 meet their acceptance criteria.

## 6. API Contract

All endpoints are versioned under /api/v1 and exchange JSON.

### 6.1 Endpoints

| Method | Path | Role | Success | Purpose |
| --- | --- | --- | --- | --- |
| POST | /customers | Admin | 201 | Create a customer |
| GET | /customers/{id} | Admin or owner | 200 | Read a customer |
| POST | /accounts | Admin or owner | 201 | Open an account |
| GET | /accounts/{id} | Admin or owner | 200 | Read an account and balance |
| PATCH | /accounts/{id}/status | Admin | 200 | Freeze, unfreeze, close |
| POST | /accounts/{id}/deposits | Owner | 201 | Deposit |
| POST | /accounts/{id}/withdrawals | Owner | 201 | Withdraw |
| POST | /transfers | Owner of source | 201 | Transfer (Idempotency-Key required) |
| GET | /accounts/{id}/transactions | Admin or owner | 200 | Paginated history |
| GET | /admin/fraud-reviews | Admin | 200 | List reviews, filter by status |
| PATCH | /admin/fraud-reviews/{id} | Admin | 200 | Clear or confirm |
| POST | /auth/register, /auth/login, /auth/refresh, /auth/logout | Public or token | 200 | Authentication |

### 6.2 Error format and codes

Errors follow the RFC 7807 problem-details shape and add a stable code field that clients can branch on.

| Code | HTTP status | Meaning |
| --- | --- | --- |
| VALIDATION\_FAILED | 400 | Malformed or invalid input, with field-level detail |
| INVALID\_TRANSACTION | 400 | Non-positive amount, more than two decimals, or same source and destination |
| UNAUTHENTICATED | 401 | Missing or invalid token |
| FORBIDDEN | 403 | Authenticated but role does not permit the action |
| NOT\_FOUND | 404 | Resource missing or not visible to the caller |
| ACCOUNT\_NOT\_ACTIVE | 409 | Account is frozen or closed |
| CONCURRENT\_UPDATE | 409 | Optimistic lock conflict; safe to retry |
| IDEMPOTENCY\_CONFLICT | 409 | Same key reused with a different request body |
| INSUFFICIENT\_FUNDS | 422 | Balance too low |
| RATE\_LIMITED | 429 | Too many attempts |

### 6.3 Concurrency and retry contract

A CONCURRENT\_UPDATE response means nothing was changed and the same request may be retried. Combined with the Idempotency-Key, retrying is always safe: the worst case is a repeated identical response. The documentation states this contract explicitly.

## 7. Non-Functional Requirements

| Area | Requirement |
| --- | --- |
| Correctness | Exact decimal money arithmetic. Transfers atomic. Balance reconciles to the ledger at all times. |
| Concurrency | Optimistic locking on accounts. A dedicated test fires many simultaneous transfers at two accounts and asserts conservation of money. |
| Performance | Single-instance target: transfer p95 under 200 ms at 50 concurrent users on free-tier hardware. Measured and recorded, not just assumed. |
| Reliability | No event loss on broker or relay failure. Consumers idempotent. |
| Security | No secrets in source. Passwords hashed. Dependencies scanned in CI. Least-privilege database user. |
| Maintainability | Layered structure with domain rules on entities, thin controllers, one error-handling component. Database changes only through versioned migrations. |
| Portability | Runs identically locally and in CI via containers. |
| Privacy | No real personal data. Logs never contain passwords, tokens, or full account identifiers beyond what is needed. |

## 8. Testing Strategy

- **Unit tests** for all domain rules and the transaction service using mocks for persistence: positive and negative amounts, scale limits, exact-balance withdrawal, frozen accounts, same-account transfer, unknown account.
- **Integration tests** against a real PostgreSQL started by Testcontainers: migrations apply cleanly, repositories behave, endpoints return the documented status codes and error codes.
- **Concurrency test**: many parallel transfers between the same accounts, asserting no drift and that every request either succeeded or received the retryable conflict.
- **Idempotency test**: the same transfer submitted repeatedly moves money once.
- **Reconciliation test**: after a randomized sequence of operations, every account balance equals the sum of its ledger.
- **Security tests**: ownership enforcement, role gating, token expiry, refresh reuse detection, login throttling.
- **Messaging tests**: outbox relay survives restart, consumer ignores duplicates, dead-letter routing, flag feedback loop end to end.
- **Coverage target**: at least 80 percent line coverage on business logic, with meaningful assertions rather than getter coverage. Coverage is enforced in the pipeline.

## 9. Risks and Open Questions

| Risk or question | Mitigation or decision needed |
| --- | --- |
| Scope is large for a solo project | Phases 1, 2, 3, and 5 are the committed core. Phase 4 beyond health and logging, and Phase 6, are cut first. |
| Free-tier hosting limits (sleeping instances, no managed Kafka) | Decide early whether the live deployment runs core only with the event pipeline demonstrated locally and in a recorded walkthrough. |
| Optimistic locking under hot-account contention causes many conflicts | Acceptable for a demo workload. Document the alternative, pessimistic row locking, and the trade-off. |
| Redis cache correctness | Keep it optional and display-only. Cut if it cannot be proven consistent. |
| Authentication scope creep | Keep a simple built-in token service. Do not add social login or external identity providers. |
| Open: should flagged transactions ever be held rather than flagged after the fact? | v1 flags only. A hold-and-release workflow is a possible later extension. |
| Open: which free-tier provider for deployment | Decide before Phase 5 based on current free-tier terms. |

## 10. Success Criteria

1. All Phase 1 to 3 and Phase 5 acceptance criteria pass in the pipeline.
2. The concurrency, idempotency, and reconciliation tests pass consistently, not intermittently.
3. Business-logic coverage is at least 80 percent with meaningful tests.
4. A public documentation URL is reachable and seeded demo data lets a reviewer try a transfer within two minutes.
5. The README contains an architecture diagram, setup steps, the design decisions with reasons (ledger model, outbox, idempotency, optimistic locking), and a short list of known limitations.
6. The author can explain, without notes, why the outbox exists, how a retried transfer is made safe, and what happens when two transfers hit one account at the same instant.

## 11. Milestones and Build Order

| Milestone | Scope | Exit condition |
| --- | --- | --- |
| M1 | Phase 1 with pipeline and local compose | FR-1.x met, pipeline green |
| M2 | Phase 2 security | FR-2.x met, ownership and role tests passing |
| M3 | Phase 3 outbox, service split, fraud rules | Event flow works end to end including failure cases |
| M4 | Phase 4 observability and circuit breaker | Correlation id traces across both services, breaker demonstrably trips and recovers |
| M5 | Phase 5 deployment | Public docs URL live, seed data documented |
| M6 | Polish and optional Phase 6 | README complete, known limitations listed |

## 12. Technology Summary

| Layer | Choice | Reason |
| --- | --- | --- |
| Language | Java 21 | Current long-term-support release, matches bank job postings |
| Framework | Spring Boot 3.x with Spring Data JPA and Spring Security | Industry-standard stack |
| Database | PostgreSQL with versioned migrations | Strong transactional guarantees, exact numeric type |
| Messaging | Apache Kafka | Common in bank event architectures |
| Cache | Redis (optional) | Demonstrates cache-aside with invalidation |
| Resilience | Resilience4j | Circuit breaker, timeout, retry |
| API docs | OpenAPI via springdoc | Interactive docs for reviewers |
| Testing | JUnit 5, Mockito, Testcontainers | Real-database integration tests |
| Delivery | Docker, compose, GitHub Actions | Reproducible builds |
| Hosting | Free-tier cloud host, to be decided before Phase 5 | Cost |
