# shop

A small online shop in Bynk, split into four bounded contexts that talk over
Service Bindings and events, with one adapter that takes payments from a
payment processor's HTTP API. It is a showcase and a test: the
[org canary](https://github.com/bynk-lang/.github/blob/main/canary/README.md)
re-runs its checks, including end-to-end scenarios against the running Workers,
on every new Bynk release.

## The shape

```mermaid
flowchart LR
  customer(["customer / admin<br/>(bearer token)"]) -- HTTP --> orders
  orders["<b>shop.orders</b><br/>Order agent: a state machine<br/>HTTP API"] -- "reserve / commit / release / restock / level<br/>(Service Binding)" --> inventory["<b>shop.inventory</b><br/>Inventory agent: holds, invariant<br/>cron: release stale holds<br/>queue: warehouse deliveries"]
  orders -- "authorise<br/>(Service Binding)" --> payments["<b>shop.payments</b><br/>Processor capability<br/>Payment agent, webhook"]
  payments -- "given Gateway<br/>(in process)" --> gateway["<b>shop.gateway</b><br/>adapter: TypeScript binding<br/>given Fetch, Secrets"]
  gateway -- "HTTPS" --> processor(["payment processor"])
  processor -- "signed webhook" --> payments
  orders -. "OrderPlaced / OrderCancelled<br/>(events)" .-> ledger["<b>shop.ledger</b><br/>Books agent<br/>idempotent subscribers"]
```

| Context | Shows | Source |
| --- | --- | --- |
| `shop.orders` | an agent as a **state machine** (`Pending → Opened → Placed / Rejected → Cancelled`); a service that coordinates other contexts; **authentication and authorisation** (a `Customer`, and an `Admin` refined by a token claim: `401` vs `403`); emitting **events** | [`orders.bynk`](src/shop/orders.bynk) |
| `shop.inventory` | an agent with an **invariant** (`available >= 0`) enforced at every commit; a **`Map`** of holds stamped with the **`Clock`**, read back with a **`Query`**; a **cron** entry point that releases stale holds; a **queue** consumer for the warehouse's deliveries, deduped by id in a **`Log`**; `on call` services with the **`Caller`** identity | [`inventory.bynk`](src/shop/inventory.bynk) |
| `shop.payments` | a **capability** (`Processor`) whose provider is composed from an adapter's capability and `Secrets`, with a fake for tests and local runs; a `Payment` agent whose history is a **`Log`** with **`@retain`**; a webhook authenticated by a **`Signature`** actor | [`payments.bynk`](src/shop/payments.bynk) |
| `shop.gateway` | an **adapter**: the `Gateway` capability declared in Bynk, implemented in a **TypeScript binding** against a payment processor's HTTP API, with `Fetch` and `Secrets` as capability dependencies | [`gateway.bynk`](src/shop/gateway.bynk), [`gateway.binding.ts`](src/shop/gateway.binding.ts) |
| `shop.ledger` | **event subscribers** (`from Events(…)`), made safe for at-least-once delivery with `Idempotency` | [`ledger.bynk`](src/shop/ledger.bynk) |

The agent owns an order's state and the rules for moving it. The service around
it does the cross-context work: reserve stock, take payment, commit the stock
if the payment is authorised or release it if not, emit the event.

That compensation is by hand, so it is not crash-safe: a Worker that dies
between reserving the stock and settling the payment leaves the stock held.
Each hold records when it was made, and a cron job in `shop.inventory` releases
holds older than fifteen minutes every five. If it releases one whose request
was only slow, the order's `commit` finds no hold and the order is rejected
rather than overselling.

## Payments

`shop.payments` charges through its `Processor` capability. A context has one
provider per capability, so the provider, `CardProcessor`, chooses from
configuration:

- `PAYMENTS_PROCESSOR=fake` uses the fake processor, a pure function: charges
  over 1,000.00 (`cents > 100000`) are declined, and the authorisation id is
  `fake_<order id>`. Tests and `bynk dev` use it.
- Anything else, including unset, goes to the real processor through the
  `shop.gateway` adapter, which reads `PAYMENTS_API_KEY` (and optionally
  `PAYMENTS_API_URL`) from `Secrets`. Without a key it fails closed: the charge
  is `Unavailable` and the order is a `503`.

The processor is generic but real-shaped:
`POST /v1/authorisations` with a bearer key, an `Idempotency-Key` (the order
id), and `{"amount", "currency", "reference"}`; `201 {"id", "status":
"authorised"}` or `402` for a declined card.

It calls back with webhooks, `POST /webhooks/processor` on `shop.payments`,
signed with HMAC-SHA256 over `<timestamp>.<body>` using
`PAYMENTS_WEBHOOK_SECRET`, in `X-Processor-Signature` and
`X-Processor-Timestamp`. A missing, forged or more than five-minute-old
signature is a `401` before the body is read. The body is
`{"id", "event", "payment"}`, where `event` is `payment.captured`,
`payment.failed` or `payment.refunded`. Each payment keeps its notices in a
`Log` for 90 days, which is also how a retried notice is recognised and
answered without being applied twice. A notice that does not follow from the
payment's status is a `409`, and the processor retries it.

## The API

Every route but the stock ones needs a bearer token (HS256, signed with
`AUTH_JWT_SECRET`) whose `sub` is the caller. The stock routes and the ledger
need a token with an `admin` claim.

| Route | Who | What |
| --- | --- | --- |
| `PUT /orders/:id` | customer | Place order `:id`: `{"sku":"widget","qty":3,"cents":2500}`. `201` placed, `400` if a field fails its type (a zero `qty`, an empty `sku`), `409` out of stock or already decided, `422` payment declined. The id is the customer's, so placing it twice cannot place it twice. |
| `GET /orders/:id` | the order's customer | The order. Someone else's is a `404`. |
| `POST /orders/:id/cancel` | the order's customer | Cancel a placed order and return its stock. |
| `PUT /stock/:sku` | admin | Add `{"qty":10}` to a product's stock. |
| `GET /stock/:sku` | anyone | Whether a product is in stock: `{"kind":"InStock"}` or `{"kind":"SoldOut"}`. A customer sees how many are left: `{"kind":"Left","count":10}`. |
| `GET /totals` (on `shop.ledger`) | admin | Standing orders, units and cents, as the ledger saw them in events. |
| `POST /webhooks/processor` (on `shop.payments`) | the payment processor (signed) | A notice about a payment: `{"id":"evt_1","event":"payment.captured","payment":"auth_123"}`. `200` with the payment's new status, `409` if it does not follow, `401` unsigned or stale. |

`PUT /orders/:id` is `422` when the card is declined and `503` when the
processor cannot be asked.

## Run it

```sh
bynkc test .                                       # unit tests
node --test tests/bindings/*.test.cjs              # the adapter's binding, after bynkc test
bynk dev -- --var AUTH_JWT_SECRET:dev-secret \
  --var PAYMENTS_PROCESSOR:fake --var PAYMENTS_WEBHOOK_SECRET:dev-hook \
  --test-scheduled                                 # all four contexts, wired
```

`--test-scheduled` lets you run the sweeper on demand:
`curl "http://localhost:8787/__scheduled?cron=*/5+*+*+*+*"`.

`bynk dev` prints each context's port. They are assigned in name order, so
`shop-inventory` is first and `shop-orders` is on the third.

## Tests

- **Unit tests** ([`tests/shop`](tests/shop)) drive the agents and services
  directly: stock arithmetic and the refusal that keeps it non-negative, holds
  and the sweeper (with a stubbed `Clock` and a scheduled time), every
  transition of the order's state machine, the fake processor's limit, the
  real path with `Gateway` stubbed, and the payment's webhook transitions and
  replay guard.
- **Binding tests** ([`tests/bindings`](tests/bindings)) test the adapter's
  TypeScript binding as TypeScript, with Node's test runner, against fake
  `Fetch` and `Secrets`: the request it sends, and how it reads each answer.
- **End-to-end scenarios** ([`e2e/scenarios.sh`](e2e/scenarios.sh)) run against
  the four Workers served by `bynk dev`, through
  [`bynk-dev`](https://github.com/bynk-lang/bynk-dev). They place, refuse,
  decline and cancel orders and check the stock after each; check that
  authentication fails as `401` and authorisation as `403`; poll the ledger
  until its events have been counted; send the payment webhook signed, forged,
  stale and twice; and run the sweeper.

  ```sh
  bynk dev -- --var AUTH_JWT_SECRET:dev-secret --var PAYMENTS_PROCESSOR:fake \
    --var PAYMENTS_WEBHOOK_SECRET:dev-hook --test-scheduled &
  AUTH_JWT_SECRET=dev-secret PAYMENTS_WEBHOOK_SECRET=dev-hook \
  BYNK_DEV_URL_SHOP_INVENTORY=http://localhost:8787 BYNK_DEV_URL_SHOP_LEDGER=http://localhost:8788 \
  BYNK_DEV_URL_SHOP_ORDERS=http://localhost:8789 BYNK_DEV_URL_SHOP_PAYMENTS=http://localhost:8790 \
    ./e2e/scenarios.sh
  ```

CI runs both on every push and pull request at a pinned Bynk version
(`0.330.4`), so a red build means a change broke something. The canary runs
them at each new release; when a release breaks the shop it opens a `canary`
issue here.

## What Bynk can't do for this yet

Where this example works around the language, or the toolchain falls short, it
is written down here rather than hidden:

- **The services between contexts are reachable from outside once deployed.**
  At 0.330.4 a context's Worker answers its `on call` services on every route
  it has, including Cloudflare's default `workers.dev` address, and trusts the
  caller name a request claims. So anyone who finds, say, the inventory
  Worker's address could restock it. Bynk's main branch signs every call
  between contexts with a key per pair
  ([bynk-lang/bynk#2004](https://github.com/bynk-lang/bynk/pull/2004),
  [#2012](https://github.com/bynk-lang/bynk/pull/2012)), not yet released.
  Turning the `workers.dev` address off doesn't last: the generated
  `wrangler.toml` sets neither `routes` nor `workers_dev`, so Wrangler turns
  it back on at every deploy. And it wouldn't help `shop.payments` or
  `shop.ledger`, because every route a Worker has serves the internal paths
  too. Deploy the shop to try it, not to take real money, until the fix is
  released.
- **The Workers build doesn't type-check, and so there is no `system` suite.**
  `shop.ledger` subscribes to events whose fields are commons types (`Sku`,
  `Cents`, …), and the serialiser Bynk emits for it names the orders
  context's namespace without importing it
  ([bynk-lang/bynk#2027](https://github.com/bynk-lang/bynk/issues/2027)).
  `bynk dev` and `bynk deploy` still work, because Wrangler's bundler strips
  types without checking them. But a `system` test suite compiles every
  context as a Worker and type-checks it, so the shop can't have one until
  the fix lands.
- **An agent can't call another context.** The `Order` agent would naturally
  call the inventory itself, but that faults at runtime
  ([bynk-lang/bynk#1960](https://github.com/bynk-lang/bynk/issues/1960)), so the
  `api` service does the cross-context calls and the agent keeps to its own
  state.
- **Events and `bynk deploy` don't compose.** Orders emit to the ledger, and a
  subscriber must consume the emitter, so the generated Service Bindings form a
  cycle and the deploy is refused
  ([bynk-lang/bynk#1961](https://github.com/bynk-lang/bynk/issues/1961)). Until it
  is fixed, [`deploy.yml`](.github/workflows/deploy.yml) is manual and the
  canary skips its deploy dry run.
- **No `system`-tier test of the whole flow.** `bynkc test`'s `system` tier
  stands the contexts up in process, but only `on call` services are
  addressable, and it wires no event fan-out
  ([bynk-lang/bynk#1959](https://github.com/bynk-lang/bynk/issues/1959)). The
  end-to-end scenarios cover the flow against the real Workers instead.
- **A `bynkc test` case can't reach an adapter's binding.** Promoting a case
  to `as integration` should run the real binding, but at 0.330.4 the adapter's
  provider is not instantiated, and a `suite` aimed at the adapter itself
  emits TypeScript that does not compile
  ([bynk-lang/bynk#1975](https://github.com/bynk-lang/bynk/issues/1975)). The
  binding is tested with Node instead ([`tests/bindings`](tests/bindings)).
- **A map can't be keyed by an opaque type.** `Map[Sku, …]` checks clean, but
  collecting its keys emits TypeScript that `tsc` rejects
  ([bynk-lang/bynk#1982](https://github.com/bynk-lang/bynk/issues/1982)). The
  inventory's holds and the catalogue are keyed by text (`orderRef`,
  `skuRef` in `shop.values`) and keep the opaque value inside the entry.
- **Three smaller workarounds in the tests and the sweep.** Each passes
  `bynkc check` and then fails, so the shop does it the other way:
  - A test that calls a `by c: Caller` service must say who is calling
    (`… by Caller("shop.orders")`); leaving it out fails `tsc` instead of being
    reported ([bynk-lang/bynk#1978](https://github.com/bynk-lang/bynk/issues/1978)).
  - A test compares a result with `expect r is Ok("…")`, because
    `expect r == Ok("…")` is type-checked against the case's own result type
    ([bynk-lang/bynk#1979](https://github.com/bynk-lang/bynk/issues/1979)).
  - `releaseStale` projects each map entry into a `Stale` record before
    collecting it, because folding a `List[MapEntry]` emits an unimported type
    ([bynk-lang/bynk#1977](https://github.com/bynk-lang/bynk/issues/1977)).
- **One provider per capability.** There is no way to pick a provider per
  environment, so `CardProcessor` reads `PAYMENTS_PROCESSOR` and chooses at
  run time. The fake is a pure function rather than a provider of its own.
- **The gateway can't void an authorisation yet.** If the sweeper releases a
  hold while its payment is being taken, the order is rejected but the
  authorisation stands until the processor lets it lapse.
- **Bynk can't send to a queue.** Producing queue messages isn't a first-party
  capability at 0.330.4, so `stock-deliveries` is fed by the warehouse's own
  Worker, and nothing in this repository can put a message on it under
  `bynk dev`. The consumer is tested with `deliveries.message(…)`.
- **The sweeper visits every sku.** Durable Objects can't be listed, so a
  `Catalogue` agent records each sku that has been stocked, and every run asks
  each one for its stale holds. That is fine at this size; a large catalogue
  would want an index of skus with open holds.

## Deploying

Not yet; see above. When it works, [`deploy.yml`](.github/workflows/deploy.yml)
needs these repository secrets:

| Secret | Value |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | A Cloudflare API token with Workers deploy scope. |
| `CLOUDFLARE_ACCOUNT_ID` | The Cloudflare account ID. |
| `AUTH_JWT_SECRET` | The key tokens are verified with. |
| `PAYMENTS_API_KEY` | The payment processor's API key. |
| `PAYMENTS_WEBHOOK_SECRET` | The key the processor signs its webhooks with. |

Leave `PAYMENTS_PROCESSOR` unset in a deployment, so the real processor is
used. Set `PAYMENTS_API_URL` to point the gateway at a sandbox.

`bynk deploy` won't warn if a payments secret is missing. Its list of the
secrets each Worker reads leaves out `PAYMENTS_PROCESSOR` (read in a provider)
and the gateway binding's `PAYMENTS_API_KEY` and `PAYMENTS_API_URL`, yet claims
to be complete ([bynk-lang/bynk#1976](https://github.com/bynk-lang/bynk/issues/1976)).
`deploy.yml` checks the two required ones itself. If the key is missing
anyway, every order is a `503` and payments logs `processor unavailable for
<order>`.

`deploy.yml` sets `PAYMENTS_API_KEY` in a second run, for `shop.payments`
alone. A name passed to `bynk deploy` with `--secrets-file` or `--secret` is
set on every context in the run, and the processor's key has no business on
inventory or orders. The actors' secrets come from the environment instead,
which `bynk deploy` sets only on the context that declares them.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE) at
your option.
