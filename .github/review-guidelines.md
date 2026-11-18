# Review guidelines for the Bynk shop

These are the maintainers' notes for reviewing a pull request here. The shop
is a small online shop in Bynk, split into four bounded contexts (`orders`,
`inventory`, `payments` and `ledger`) and one adapter (`gateway`), talking
over Service Bindings and events. It is both a showcase of multi-context Bynk
and a test: the org canary re-runs its checks, end-to-end scenarios included,
on every new Bynk release. So a change is judged as teaching material, as a
working shop, and as a test that should keep catching regressions.

Skip what CI already enforces: `bynk fmt --check`, `bynk check`, `bynk test`,
the binding tests (`node --test tests/bindings/*.test.cjs`), the end-to-end
scenarios and the deploy's dry run, all at the pinned `BYNK_VERSION`.

## What matters most

- **Context boundaries.** Each context owns its agents and state, and others
  reach it only through its services (Service Bindings) or its events. Flag a
  change that reaches into another context's state, or moves a rule out of
  the context that owns it. The `Order` agent owns an order's state and its
  transitions; the service around it does the cross-context work.
- **Authentication and authorisation.** Every route but `GET /stock/:sku`
  and the webhook needs a bearer token, and the stock writes and the ledger
  need the `admin` claim. A missing or bad token is a `401`; a valid one
  without the right to act is a `403`; someone else's order is a `404`, so
  its existence isn't revealed. Flag a route that acts before these checks,
  or answers differently than the README's API table says.
- **The webhook.** A missing, forged or stale signature is a `401` before the
  body is read, and a retried notice is recognised and answered without
  being applied twice. A notice that doesn't follow from the payment's status
  is a `409`.
- **Secrets stay where they belong.** `PAYMENTS_API_KEY` is set on
  `shop.payments` alone, never on every context, and no secret, token or key
  appears in code, tests, fixtures or logs. Tests use the fake processor and
  stubbed `Secrets`. The gateway fails closed without a key.
- **At-least-once and money.** Placing an order twice with the same id can't
  place it twice; event subscribers are idempotent; the inventory invariant
  (`available >= 0`) holds at every commit; and an amount is whole cents,
  never a float. The compensation between reserving stock and taking payment
  is by hand, so a change to that flow must keep the sweeper's guarantee: a
  stale hold is released, and an order whose hold is gone is rejected rather
  than oversold.
- **Idiomatic Bynk.** Refined types at the boundary, `Result` rather than
  sentinel values, capabilities named in `given`, `match` where it reads
  better. Flag a workaround a reader might copy. A real limit of the language
  belongs in the README's "What Bynk can't do for this yet", not hidden in
  the code.

## Tests

- A change of behaviour comes with tests at the right level:
  - **unit tests** (`tests/shop`) for an agent's or service's rules, with
    `Clock`, `Gateway` and the other capabilities stubbed;
  - **`system` suites** (`*_system.bynk`) for behaviour across contexts, over
    the wire;
  - **binding tests** (`tests/bindings`) for the gateway's TypeScript;
  - **end-to-end scenarios** (`e2e/scenarios.sh`) for a route's behaviour
    against the running Workers.
- Look for missing failure cases: a `401` and a `403`, out of stock, a
  declined card, an unavailable processor, a forged or replayed webhook, a
  repeated order id, and a hold the sweeper has released.
- The shop is a canary. A test that is loosened, skipped or made to pass
  regardless hides a regression in Bynk itself, so it needs a reason in the
  pull request.

## Configuration and deploy

- A new secret or variable is listed in the README's "Deploying" table and in
  `deploy.yml`'s header and steps, set only on the context that reads it.
- `BYNK_VERSION` is moved by the canary's pull request, once the shop passes
  at the new release. A hand-edited pin needs a reason.

## Documentation and style

- The README describes the contexts, the payments flow, the API and the
  tests. A change to a route, an answer, a context's responsibilities or a
  workaround updates the README in the same pull request.
- British English throughout: in comments, the README and the API's messages
  ("authorise", "behaviour", "licence" as a noun).
- Comments explain why, in plain sentences, for a reader learning Bynk.

## Severity here

- **Blocking:** an authentication or authorisation hole, a webhook accepted
  unsigned or applied twice, a secret exposed or set on the wrong context, an
  order placed twice or stock oversold, state reached across a context
  boundary, or a test weakened without a reason.
- **Should fix:** a missing test at the right level, a failure answered with
  the wrong status, a README out of step with the code, or a workaround a
  reader might copy.
- **Nit:** wording, naming and small style points. Keep these few.
