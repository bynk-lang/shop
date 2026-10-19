// Tests for the TypeScript half of the `shop.gateway` adapter. A binding is
// TypeScript, so it is tested as TypeScript: against fake `Fetch` and
// `Secrets` capabilities, checking the request it sends and how it reads the
// processor's answers: the edge cases easiest to pin down in TypeScript.
//
// Run after `bynkc test .`, which compiles the project to out-js/:
//
//   bynkc test . && node --test tests/bindings/*.test.cjs
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const outJs = path.join(__dirname, "..", "..", "out-js");
const { HttpGateway } = require(path.join(outJs, "shop", "gateway.binding.js"));
const { GatewayError } = require(path.join(outJs, "shop", "gateway.js"));
const { Method, FetchError } = require(path.join(outJs, "bynk.js"));
const { Ok, Err, Some, None } = require(path.join(outJs, "runtime.js"));

// A gateway over fake capabilities: `secrets` is the environment, `answer` is
// what the network does with a request. `sent` records every request.
function gateway(secrets, answer) {
  const sent = [];
  const deps = {
    Secrets: {
      async get(name) {
        return name in secrets ? Some(secrets[name]) : None;
      },
    },
    Fetch: {
      async send(req) {
        sent.push(req);
        return answer(req);
      },
    },
  };
  return { gw: new HttpGateway(deps), sent };
}

const configured = { PAYMENTS_API_KEY: "sk_test_123" };
const reply = (status, body) => () => Ok({ status, headers: new Map(), body });

test("an authorised charge returns the processor's id", async () => {
  const { gw } = gateway(configured, reply(201, '{"id":"auth_9","status":"authorised"}'));
  assert.deepEqual(await gw.authorise("o1", 2500), Ok("auth_9"));
});

test("the request is a POST to /v1/authorisations, keyed by the order", async () => {
  const { gw, sent } = gateway(configured, reply(201, '{"id":"auth_9","status":"authorised"}'));
  await gw.authorise("o1", 2500);
  assert.equal(sent.length, 1);
  const req = sent[0];
  assert.equal(req.method, Method.Post);
  assert.equal(req.url, "https://api.processor.example/v1/authorisations");
  assert.deepEqual(req.authorization, Some("Bearer sk_test_123"));
  assert.deepEqual(req.contentType, Some("application/json"));
  assert.equal(req.headers.get("idempotency-key"), "o1");
  assert.equal(req.body.tag, "Some");
  assert.deepEqual(JSON.parse(req.body.value), { amount: 2500, currency: "gbp", reference: "o1" });
});

test("PAYMENTS_API_URL points the gateway elsewhere", async () => {
  const { gw, sent } = gateway(
    { ...configured, PAYMENTS_API_URL: "https://sandbox.processor.example/" },
    reply(201, '{"id":"auth_9","status":"authorised"}'),
  );
  await gw.authorise("o1", 2500);
  assert.equal(sent[0].url, "https://sandbox.processor.example/v1/authorisations");
});

test("a 402 is a declined card", async () => {
  const { gw } = gateway(configured, reply(402, '{"error":{"code":"card_declined"}}'));
  assert.deepEqual(await gw.authorise("o1", 2500), Err(GatewayError.Declined));
});

test("a server error is unavailable, not declined", async () => {
  const { gw } = gateway(configured, reply(503, "upstream overloaded"));
  assert.deepEqual(await gw.authorise("o1", 2500), Err(GatewayError.Unavailable));
});

test("a network failure is unavailable", async () => {
  const { gw } = gateway(configured, () => Err(FetchError.Timeout));
  assert.deepEqual(await gw.authorise("o1", 2500), Err(GatewayError.Unavailable));
});

test("a success the binding cannot read is unavailable", async () => {
  for (const body of ["not json", '{"status":"authorised"}', '{"id":"auth_9","status":"pending"}']) {
    const { gw } = gateway(configured, reply(201, body));
    assert.deepEqual(await gw.authorise("o1", 2500), Err(GatewayError.Unavailable), body);
  }
});

test("without an API key nothing is sent, and the charge is unavailable", async () => {
  for (const secrets of [{}, { PAYMENTS_API_KEY: "" }]) {
    const { gw, sent } = gateway(secrets, reply(201, '{"id":"auth_9","status":"authorised"}'));
    assert.deepEqual(await gw.authorise("o1", 2500), Err(GatewayError.Unavailable));
    assert.equal(sent.length, 0);
  }
});
