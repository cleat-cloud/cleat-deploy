# Cleat Signals — OTLP export

Cleat Speaks OpenTelemetry JSON over HTTP. There is no Cleat SDK: point the
exporter you already use at the panel, then turn sampling on per app.

## Endpoints

Both require a tenant API token (`Authorization: Bearer …`) and `app` as the
app slug or id.

| Signal | Method | Path | Sample rate (default 0) |
| --- | --- | --- | --- |
| Traces | `POST` | `/api/v1/signals/otlp/v1/traces?app=SLUG` | `trace_sample_rate` |
| Exceptions | `POST` | `/api/v1/signals/otlp/v1/logs?app=SLUG` | `exception_sample_rate` |

Rate `0` returns `202` and stores nothing. Rate `1` stores every sampled
payload. Set rates from Saúde, `cleat signals sampling`, or
`PATCH /api/v1/signals/sampling`.

The logs endpoint accepts:

- `resourceLogs` whose records carry OTel `exception.type`,
  `exception.message`, and/or `exception.stacktrace`
- `resourceSpans` with span events named `exception` (same attributes)

Generic log lines without those attributes are dropped. Stack and message
go through the same redactor as journal ingest, then the 4a fingerprint, then
the 4b issue upsert (`source: otlp`).

## Elixir (Phoenix)

Keep your existing OTLP setup (`:opentelemetry`,
`:opentelemetry_exporter`, optionally `OpentelemetryLoggerMetadata`).
Export HTTP/JSON — protobuf is not accepted yet.

```elixir
config :opentelemetry, :processors, [
  {:otel_batch_processor, %{
    exporter: {:otel_exporter_otlp, %{
      protocol: :http_json,
      endpoints: ["https://cleat.example.com/api/v1/signals/otlp/v1/traces?app=my-app"],
      headers: [{"authorization", "Bearer " <> System.fetch_env!("CLEAT_TOKEN")}]
    }}
  }}
]
```

For exceptions, attach `exception.*` attributes on the log record or on a
span event named `exception`, and point the logs exporter at
`/api/v1/signals/otlp/v1/logs?app=my-app` with the same bearer token.

`OpentelemetryLoggerMetadata` copies the current span context onto Logger
metadata so a crash log can ride the same trace id.

## Node

```js
const { NodeSDK } = require("@opentelemetry/sdk-node");
const { OTLPTraceExporter } = require("@opentelemetry/exporter-trace-otlp-http");
const { OTLPLogExporter } = require("@opentelemetry/exporter-logs-otlp-http");

const headers = { Authorization: `Bearer ${process.env.CLEAT_TOKEN}` };
const app = process.env.CLEAT_APP;

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter({
    url: `https://cleat.example.com/api/v1/signals/otlp/v1/traces?app=${app}`,
    headers,
  }),
  logRecordProcessors: [
    new (require("@opentelemetry/sdk-logs").BatchLogRecordProcessor)(
      new OTLPLogExporter({
        url: `https://cleat.example.com/api/v1/signals/otlp/v1/logs?app=${app}`,
        headers,
      })
    ),
  ],
});

sdk.start();
```

Record exceptions with the OTel semantic conventions
(`exception.type` / `exception.message` / `exception.stacktrace`), not a
Sentry envelope.

## Out of scope

Sentry `store` / `envelope`, browser RUM, source maps, session replay, and
auto-instrumentation on deploy. Cleat does not ship an SDK.
