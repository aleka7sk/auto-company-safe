**Product:** Booking Calendar

## Problem

Companies that manage short-term rental apartments with an owner and a small sales team receive preliminary reservation requests from Booking and, later, other channels. Those requests still require human contact and approval, but today they are easy to lose in chats, process too slowly, assign to nobody, or confuse with real bookings. That creates false occupancy, expired opportunities, inconsistent payment records, weak accountability, and a risk of confirming overlapping stays. The owner cannot reliably see which requests are waiting, who is responsible, how quickly the team responds, where conversion is lost, or how much potential revenue is being missed.

## Target User

The initial design target is a Kazakhstan-based owner or operator managing roughly 5–30 short-term rental units with 1–5 booking managers. The daily primary user is the on-duty manager who receives a preliminary request, contacts the guest, checks availability, creates a temporary hold when justified, and converts the request into a confirmed booking or a recorded loss reason.

## Product Boundary

Build a production-oriented **local pilot v1**, not a complete PMS and not a marketplace. The product must prove one narrow promise:

> No preliminary reservation request is lost, every request has a visible owner and SLA, and only a valid hold or confirmed booking blocks inventory.

This autonomous run creates a clean implementation in `projects/booking-calendar/`. It must not clone, fetch, overwrite, or depend on any separate Booking Calendar repository, cloud account, Figma file, or production credential. The mission below contains the required product baseline.

## Core Domain Rules

- A preliminary request is **not** a booking and does not occupy inventory.
- Keep request work state, reservation outcome, inventory occupancy, and payment state as separate domain dimensions. Do not collapse them into one ambiguous status field.
- Request work states: `RECEIVED`, `ASSIGNED`, `CONTACTING`, `RESOLVED`.
- Request outcomes: `PENDING`, `HELD`, `CONFIRMED`, `REJECTED`, `EXPIRED`, `LOST`, `CANCELLED`.
- Payment states: `UNPAID`, `PARTIAL`, `PAID`, `REFUNDED`.
- Inventory is blocked only by an active `HOLD`, a `CONFIRMED_BOOKING`, or an explicit operational `BLOCK`.
- Time ranges use half-open semantics: `[starts_at, ends_at)`. A checkout and a following check-in may touch at the same timestamp without overlapping.
- A hold has an explicit expiry. Expired holds release inventory automatically and remain visible in history.
- Creating a hold, confirming a request, moving a booking, and cancelling a booking must be transactional, idempotent where applicable, and protected against concurrent overlap.
- Every material mutation records tenant, actor, timestamp, action, previous state, new state, and relevant entity identifiers in an audit log.
- Tenant identity comes from the authenticated session. Never trust a client-supplied tenant identifier for authorization.

## In Scope

- One locally runnable multi-tenant web SaaS in `projects/booking-calendar/`, with at least two seeded companies so tenant isolation can be demonstrated and tested.
- Secure local authentication with `Owner` and `Manager` roles. Owners manage units and team members and see analytics; managers operate requests, holds, bookings, guests, contact attempts, and payments within their company.
- Core entities: tenant/company, user, rental unit, guest, incoming integration event, reservation request, contact attempt, hold, confirmed booking, operational block, payment entry, loss reason, and audit event.
- A Booking-like webhook adapter endpoint for `request.created`, `request.updated`, and `request.cancelled` sample events. It must verify a configured local signing secret, retain a safe event journal, deduplicate by external event ID, detect conflicting replays, and quarantine invalid or unprocessable events for inspection and local replay.
- A priority Request Inbox with search and filters, new/unassigned/overdue/risk queues, SLA elapsed time, assignee, source, requested unit and period, quoted amount, contact-attempt history, notes, and an explicit next action.
- Assignment and self-claim flows that prevent two managers from silently owning the same request. All assignment changes are audited.
- Availability checking across holds, confirmed bookings, and operational blocks; temporary holds with expiry; manual booking creation; atomic request-to-hold and request-to-confirmed-booking conversion; move, cancel, and release flows.
- A desktop booking board showing rental units by date range, confirmed bookings, holds, operational blocks, and non-blocking request markers with distinct semantics. Include filters and a clear legend.
- A safe confirmation flow that shows the guest, unit, period, amount, payment summary, availability result, assignee, and consequences before committing the booking.
- Manual payment ledger entries for prepayment and balance tracking. Payment state must not be used as the occupancy state.
- Manager experience: Today/Operations Home, Request Inbox, Request Detail, Booking Board, confirmation flow, bookings, guests, and visible conflict/error recovery.
- Owner experience: operational overview, request conversion funnel, median first-response time, SLA breaches, breakdown by source and manager, loss reasons, and potential lost revenue calculated only from stored quoted amounts and clearly labelled as an estimate.
- Team/SLA view and Integration Health view with last successful event, latency, duplicate count, quarantined failures, and replay result.
- Responsive web experience for desktop and phone. On desktop, prioritize the portfolio board and split-view operations. On phone, prioritize the next action, request queue/detail, confirmation, daily agenda, and owner summary; do not shrink the full desktop grid into an unreadable mobile table.
- A coherent visual system: calm premium operations software, dark evergreen navigation, warm neutral surfaces, restrained semantic colors, dense but readable information hierarchy, visible focus, and no generic gradient-heavy AI dashboard styling.
- Explicit UI states for loading, empty data, validation error, permission denial, stale data, webhook failure, expired hold, and concurrent booking conflict.
- Deterministic local demo data that demonstrates the complete flow from incoming request to assignment, contact, hold, confirmation, payment update, owner analytics, and cancellation.
- Local documentation for architecture, domain state machine, API/webhook contract, security boundaries, test strategy, and operator runbook.

## Out of Scope

- **Do not build a second product.** One product only, in `projects/booking-calendar/`.
- **Do not copy `projects/snapog/`.** It is a leftover from a previous, unrelated run (Cloudflare Workers + TypeScript). It is not the template, not the stack, and not the mission. Ignore it entirely.
- **No cloud deployment, no GitHub operations.** This run is local-only: `gh` and `wrangler` are blocked. Deployment happens later, by hand, after human review.
- No real Booking.com Connectivity Partner integration, certification, account login, browser automation, or claim that the sample webhook is an official production Booking.com contract.
- No full channel manager, iCal synchronization, dynamic pricing, or bidirectional inventory/rate management.
- No Krisha or OLX parsing/automation; no Instagram, WhatsApp, Kaspi, Halyk, OFD, eQonaq, TTLock, smart-lock, SMS, email, or other external-account integration.
- No cleaning marketplace, housekeeper application, maintenance routing, legal-document generation, fiscalization, owner payouts, public property catalog, platform subscription billing, or native iOS/Android application.
- No dedicated hourly-rental UI in v1. Store precise timestamps so a later version is possible, but optimize the first board and flows for short-term stays by day.
- No autonomous pricing, market-size, revenue, legal, or compliance claims without real evidence. Do not invent percentages, user counts, deadlines, or Kazakhstan regulatory requirements.
- No rewrite of this repository's autonomous-loop infrastructure, protected files, dashboard, scripts, agents, or skills. Product code and product documentation belong under `projects/booking-calendar/`.
- No production release claim. Completion here means a production-oriented local pilot that passes the objective Definition of Done below and is ready for human security, usability, and deployment review.

## Tech Stack

- **Backend:** Go using toolchain `go1.26.5`, implemented as a modular monolith. Use `cmd/` for entrypoints and `internal/` for domain, application, persistence, HTTP, auth, integrations, and observability packages. Prefer the standard library and small, justified dependencies.
- **Dependency workflow is unusual here:** the autonomous agent builds with `GOPROXY=off`. Add required imports normally; do not treat `go get` failure as a product defect. The unsandboxed supervisor runs `go mod tidy` and warms the module cache between cycles.
- **Storage:** SQLite with versioned SQL migrations, foreign keys enabled, transactional writes, deterministic seed data, and a database path configurable through a non-secret environment variable. Use a pure-Go driver unless an objective reason requires otherwise.
- **HTTP/API:** versioned JSON REST endpoints, typed error responses, request IDs, bounded request bodies, sensible timeouts, and an OpenAPI document for the implemented contract.
- **Authentication:** password hashing suitable for production, opaque server-side sessions or equivalently safe session handling, `HttpOnly` and `SameSite` cookies, CSRF protection for cookie-authenticated mutations, and tenant-scoped authorization at the application/persistence boundary.
- **Frontend:** React + TypeScript + Vite in `projects/booking-calendar/web/`. Use accessible semantic HTML, a small reusable component system, CSS variables/design tokens, responsive layouts, and the repository's `frontend-design` skill before UI implementation. Avoid unnecessary framework churn.
- **Delivery shape:** the release-mode Go service serves the built frontend and API from one local process. Development may use separate Vite and Go processes, but the documented release-like start must be one command.
- **Testing:** Go unit and integration tests for domain/persistence/HTTP behavior; frontend tests with Vitest and React Testing Library or an equally objective local alternative; a local smoke test using a fresh temporary database.
- **Observability:** structured logs without secrets or raw webhook credentials, request and event correlation IDs, `/healthz`, `/readyz`, and useful error messages for operators.
- **Runtime:** all core product flows must work locally without any third-party account or outbound network access after dependencies are installed.

## Definition of Done

- [ ] `go build ./...` completes with no errors from `projects/booking-calendar/`
- [ ] `go vet ./...` reports nothing from `projects/booking-calendar/`
- [ ] `go test ./...` passes from `projects/booking-calendar/` and covers the core domain, persistence, authorization, webhook, and HTTP behavior
- [ ] The service starts locally with the single documented command `make run` from `projects/booking-calendar/`
- [ ] `README.md` in `projects/booking-calendar/` explains the product boundary, prerequisites, local setup, demo accounts, how to run, how to test, and known limitations
- [ ] `npm ci --prefix web` and `npm run build --prefix web` both succeed from `projects/booking-calendar/`
- [ ] `npm test --prefix web` runs non-interactively and passes the frontend component and workflow tests
- [ ] `make smoke` starts the product against a fresh temporary database, verifies `/healthz` and `/readyz`, executes the core request-to-confirmed-booking flow, and exits successfully
- [ ] Versioned migrations can create a fresh SQLite database, and a documented seed command creates two isolated demo tenants with owners, managers, units, requests, holds, bookings, blocks, payments, and integration events
- [ ] Automated authorization tests prove that a user from tenant A cannot read or mutate tenant B data, even when tenant B identifiers are supplied directly to API endpoints
- [ ] Automated role tests prove that managers cannot perform owner-only team/unit administration while owners can, and unauthenticated mutations are rejected
- [ ] Webhook tests prove signature validation, idempotent duplicate delivery, update/cancel handling, conflicting-replay quarantine, and safe local replay without creating duplicate requests
- [ ] Domain tests prove that request work state, request outcome, occupancy, and payment state remain independent and reject invalid transitions
- [ ] Availability tests prove that `RECEIVED`/`ASSIGNED`/`CONTACTING` requests do not block inventory, while active holds, confirmed bookings, and operational blocks do
- [ ] Hold-expiry tests prove that an expired hold releases availability without deleting history and that a later confirmation cannot revive an expired hold implicitly
- [ ] A concurrent-overlap integration test issues competing hold or confirmation attempts for the same unit and period and proves that exactly one succeeds while the others receive a typed conflict response
- [ ] Workflow tests cover assignment/self-claim, SLA breach calculation, contact attempts, notes, hold, confirmation, rejection, expiration, loss reason, cancellation, and audit history
- [ ] Confirmation and cancellation integration tests prove that reservation, occupancy, payment summary, request outcome, and audit mutations commit atomically or roll back together
- [ ] Frontend tests cover the required desktop and phone flows: Operations Home, Request Inbox/detail, Booking Board or mobile agenda, confirmation, Owner Overview, Team/SLA, and Integration Health
- [ ] Frontend tests cover loading, empty, validation, permission, stale-data, expired-hold, webhook-failure, and booking-conflict states with keyboard-reachable primary actions and visible focus styling
- [ ] Analytics tests calculate a deterministic conversion funnel, median first-response time, SLA breaches, manager/source breakdown, loss reasons, and potential lost revenue from fixture data without double-counting requests
- [ ] The Integration Health screen and API expose last success, event latency, duplicate deliveries, quarantined failures, and replay outcome without exposing signing secrets or raw sensitive values
- [ ] Every create, assign, contact, hold, confirm, move, payment, cancel, block, replay, and administrative action is represented in an immutable tenant-scoped audit trail and verified by tests
- [ ] `docs/architecture.md`, `docs/domain-state-machine.md`, `docs/openapi.yaml`, `docs/security-boundaries.md`, `docs/test-strategy.md`, and `docs/operator-runbook.md` exist under `projects/booking-calendar/` and match the implemented behavior
- [ ] No core runtime path requires Booking, WhatsApp, Kaspi, Figma, GitHub, Cloudflare, or any other external service; all external adapters are local fakes behind documented interfaces
