# Deploy E2E (disposable server)

`Deploy E2E` validates the **real** deploy path — SSH, source upload, publish,
Caddy and HTTP — on a throwaway Hetzner Cloud server. The regular CI job runs
`mix test --exclude integration`, so this workflow is the only place the whole
flow is exercised end to end.

## What it validates

1. **Initial deploy** of the reference app (`E2E_REF`): the deployment reaches
   `success` and `http://<server-ip>/` answers `200`.
2. **Update**: a second deploy of the same app also succeeds and keeps serving.
3. **Build failure** (`E2E_FAIL_BUILD_REF`): the deployment reaches `failed` and
   the previous release keeps answering `200`.
4. **Release failure** (`E2E_FAIL_RELEASE_REF`, optional): same assertion, with
   a `.cleat_deploy/deploy.json` whose `release_command` exits non-zero.

The harness drives `CleatDeploy.Deploy.SshRunner` directly, exactly like the
deploy worker does, with a temporary SQLite database and a dedicated tenant.

## Coverage by runtime

Static is the initial scope: it exercises clone/upload, release publishing,
`current` swap, Caddy install/reload and the HTTP path without a toolchain
build. Other runtimes are added by extending the harness (one reference app per
runtime) — Phoenix, Go, Node, Rails, Rust and Gleam still need their own
reference repo and assertions before they are claimed here.

## Configuration

The job runs in the **`deploy-e2e`** GitHub environment. Configure:

| Kind | Name | Description |
|---|---|---|
| secret | `CLEAT_E2E_HCLOUD_TOKEN` | Hetzner Cloud token from a **dedicated** e2e project |
| secret | `CLEAT_E2E_SSH_PRIVATE_KEY` | Private key dedicated to e2e servers |
| variable | `CLEAT_E2E_REPO` | Reference repo (`owner/repo`), default `cleat-cloud/cleat-e2e-reference` |
| variable | `CLEAT_E2E_EXPECT_BODY` | Optional substring expected in the HTTP response |
| variable | `CLEAT_E2E_FAIL_BUILD_REF` | Override the failing-build branch |
| variable | `CLEAT_E2E_FAIL_RELEASE_REF` | Override the failing-release branch |

The reference repo must be public. It must contain:

- `main`: a static site with `index.html` at the repo root.
- `cleat-e2e-fail-build`: a branch that breaks the deploy.
- `cleat-e2e-fail-release`: a branch with
  `.cleat_deploy/deploy.json` → `{"runtime": "static", "release_command": "exit 1"}`.

If a failure branch does not exist, the clone itself fails — the harness still
sees a failed deploy and the previous release serving, but the build/release
phase is not the one being covered.

## Running

Manual: **Actions → Deploy E2E → Run workflow** (ref, failure refs and server
type can be overridden).

Scheduled: weekly (`0 3 * * 1`). The job skips with a warning when the two
secrets are absent, so the schedule can be enabled before the environment is
configured.

Locally, with the same environment variables:

```bash
export HCLOUD_TOKEN=...
export E2E_SSH_PRIVATE_KEY_PATH=~/.ssh/cleat-e2e
export E2E_REPO=cleat-cloud/cleat-e2e-reference
scripts/e2e/run.sh
```

Set `E2E_KEEP_SERVER=1` to keep the server for debugging (billing continues).

## Cost and cleanup

A `cx22` (2 vCPU / 4 GB) is created per run and destroyed at the end. Hetzner
bills hourly; a run costs a few cents, and `E2E_SERVER_TYPE=cx33` is the
heavier option. There is no time estimate here because the duration depends on
the base image and network.

Every resource (server, firewall, SSH key, local key file) is removed by a
`trap` on exit, including failure and SIGTERM. The job itself has a hard
`timeout-minutes: 45` and the harness a 30-minute `timeout`. If the runner dies
before the trap runs, find leftovers by label and delete them:

```bash
curl -fsS -H "Authorization: Bearer $HCLOUD_TOKEN" \
  'https://api.hetzner.cloud/v1/servers?label_selector=purpose%3Dcleat-e2e'
```

## Results and secrets

- The run page and the `deploy-e2e-summary` artifact (JSON: step statuses,
  deployment ids, timings, server IP — **no logs**) are the result history.
  The artifact is kept for 14 days.
- The SSH key and Hetzner token are passed through masked secrets and never
  echoed; the key is written to a `0600` temp file and deleted by the trap.
- The harness never prints raw deploy logs (they can contain the clone URL).
