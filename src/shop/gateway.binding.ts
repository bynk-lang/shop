// The host half of the `shop.gateway` adapter: a payment processor's HTTP API
// behind the `Gateway` capability. The processor is generic but real-shaped:
//
//   POST {PAYMENTS_API_URL}/v1/authorisations
//   Authorization: Bearer {PAYMENTS_API_KEY}
//   Idempotency-Key: {reference}
//   {"amount": 2500, "currency": "gbp", "reference": "o1"}
//
//   201 {"id": "auth_123", "status": "authorised"}
//   402 {"error": {"code": "card_declined"}}
//
// Outbound IO and configuration are capability dependencies (`Fetch`,
// `Secrets`), so the binding never calls the global `fetch` or reads `env`.
import type { Gateway } from "./gateway.js";
import { GatewayError } from "./gateway.js";
import type { Fetch, Secrets } from "../bynk.js";
import { Method } from "../bynk.js";
import { Ok, Err, Some, type Result } from "../runtime.js";

const DEFAULT_API_URL = "https://api.processor.example";

export class HttpGateway implements Gateway {
  // A declared field and an assigning constructor, not a parameter property,
  // so the binding also runs under Node's `--experimental-strip-types`.
  private deps: { Fetch: Fetch; Secrets: Secrets };
  constructor(deps: { Fetch: Fetch; Secrets: Secrets }) {
    this.deps = deps;
  }

  async authorise(reference: string, cents: number): Promise<Result<string, GatewayError>> {
    const key = await this.deps.Secrets.get("PAYMENTS_API_KEY");
    if (key.tag !== "Some" || key.value === "") {
      return Err(GatewayError.Unavailable);
    }
    const url = await this.deps.Secrets.get("PAYMENTS_API_URL");
    const base = url.tag === "Some" && url.value !== "" ? url.value : DEFAULT_API_URL;

    const res = await this.deps.Fetch.send({
      method: Method.Post,
      url: `${base.replace(/\/+$/, "")}/v1/authorisations`,
      contentType: Some("application/json"),
      authorization: Some(`Bearer ${key.value}`),
      headers: new Map([["idempotency-key", reference]]),
      body: Some(JSON.stringify({ amount: cents, currency: "gbp", reference })),
    });
    if (res.tag === "Err") {
      return Err(GatewayError.Unavailable);
    }
    const { status, body } = res.value;
    if (status === 402) {
      return Err(GatewayError.Declined);
    }
    if (status !== 200 && status !== 201) {
      return Err(GatewayError.Unavailable);
    }
    const id = authorisationId(body);
    return id === undefined ? Err(GatewayError.Unavailable) : Ok(id);
  }
}

// The authorisation id from a success body, or `undefined` if the body is not
// the shape the processor documents.
function authorisationId(body: string): string | undefined {
  try {
    const parsed: unknown = JSON.parse(body);
    if (typeof parsed === "object" && parsed !== null) {
      const { id, status } = parsed as { id?: unknown; status?: unknown };
      if (typeof id === "string" && id !== "" && status === "authorised") {
        return id;
      }
    }
  } catch {
    // Not JSON: fall through.
  }
  return undefined;
}
