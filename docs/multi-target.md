# Mom: one monitor for several projects (design, 2026-11-09)

Approved by Jef on 2026-11-09.

## Goal

One Mom, on a small server of its own, watches School, Latte and revivehub.
Each project tells Mom what it is (repository, release, commit). An agent,
remote (for example Claude Code with `/loop`) or local on the Mom server,
checks the health of all projects through one short answer. Only holders of
a valid token can read it.

## What stays

- Mom watches an app from outside, over Erlang distribution (Jef: "Everything
  is elixir, so the erlang ports seem simplest. We don't reinvent that
  part."). `Mom.Beam` still installs the logger and telemetry handlers in the
  app; events still come to Mom without polling.
- The pipeline, triage worker, governance and rate limits stay as they are.
  Each target gets its own `Mom.Config`.

## 1. The server

- A new EC2 t4g.small (ARM, 2 GB) in `vpc-6db4550b`, the network of the apps.
  Name `mom`. Security group `mom`.
- Mom runs as an OTP release under systemd (`mom.service`), like School.
  Settings come from SSM Parameter Store, `/mom/*`, at start.

## 2. Connections to the apps

- Each app runs its release as a named node on its private address
  (`RELEASE_DISTRIBUTION=name`, `RELEASE_NODE=<app>@<private ip>`), with the
  distribution port fixed: `-kernel inet_dist_listen_min 9100
  inet_dist_listen_max 9105`.
- Each app's security group accepts TCP 4369 (epmd) and 9100 to 9105 from the
  `mom` security group only.
- Each app keeps its own cookie. Mom reads the cookies from SSM
  (`/mom/targets/<app>/cookie`) and sets them per node with
  `:erlang.set_cookie(node, cookie)`. Mom's own cookie is a separate secret.

## 3. Targets

A target is one app Mom watches. The list is configuration, read at start
(`/mom/targets`, a JSON list), for example:

```json
[{"name": "school", "node": "school@172.30.2.137", "triage": "off"},
 {"name": "latte", "node": "latte@172.30.2.120", "triage": "report", "agent": "claude_code"}]
```

- A supervisor (`Mom.Targets.Supervisor`) runs one watcher per target. A
  watcher is the present `Mom.Runner` loop with that target's config.
- A watcher that cannot reach its node retries with backoff and reports
  `down`. A node that goes away and comes back gets its handlers installed
  again, and its project info read again.
- `triage` is `off`, `report` or `fix`; `agent` is `claude_code` or `codex`.
  `off` records errors and does not call an agent.

## 4. Project info

Each app declares, in its own runtime configuration:

```elixir
config :mom_info,
  name: "school",
  repo: "improvingjef/school",
  env: "production",
  release: "0.1.0",
  commit: System.get_env("RELEASE_COMMIT")   # written by the deploy script
```

Mom reads it over the connection (`:rpc.call(node, Application,
:get_all_env, [:mom_info])`) when it connects and after each reconnect. The
target's `repo` from here is the repository Mom uses for issues and fixes.
An app without `:mom_info` still works; its info shows as unknown.

## 5. Status

`Mom.Status` keeps, per target, in ETS:

- state: `ok` (connected, no error in the last hour), `warn` (errors in the
  last hour), `down` (not connected), `unknown` (not yet connected);
- the project info, connected since, last event;
- the errors of the last 24 hours (time, kind, short message, fingerprint),
  at most 200 per target.

## 6. The endpoint

Bandit and Plug, on port 4400, behind the existing load balancer
`ttr-lb` with a host rule for `mom.reviveschool.org` (working name), so the
answer is HTTPS with the existing certificate.

- `GET /status` (text, one line per target):

  ```
  school  ok    0.1.0 4db6647  errors 1h: 0
  latte   warn  0.1.0 9f2c1aa  errors 1h: 3  last 13:52 Postgrex timeout
  revivehub down                connected: no since 12:10
  ```

- `GET /status?format=json`: the same data as JSON.
- `GET /status/<target>`: the recent errors of one target.
- `GET /health`: no token, answers `ok` for the load balancer only.

## 7. Authentication

- Each agent gets its own token, sent as `Authorization: Bearer <token>`.
  Mom stores only the SHA-256 hash of each token, with its name and the time
  it was made (a small file under the release's data directory).
- A token is made and revoked on the Mom server:
  `bin/mom rpc 'Mom.Tokens.new("claude-loop")'`, `Mom.Tokens.revoke/1`. The
  token text is shown once.
- Wrong or missing token: 401, and failed attempts are limited per address
  (10 a minute).
- The endpoint is reached only through the load balancer: the `mom`
  security group accepts port 4400 from the load balancer only.

## 8. A local agent

The `triage` and `agent` settings of a target make the agent on the Mom
server triage that target's errors, as Mom does now. The agent's command
line (`claude` or `codex`) is installed on the Mom server only when a target
uses it.

## Order of work

1. Mom: targets, project info, status, endpoint, tokens, release. Tests.
2. The server, security groups, DNS and the load balancer rule.
3. School: named node, fixed ports, `:mom_info`, cookie in SSM. Then Latte.
4. Revivehub, after a look at its setup.

## As built (2026-11-09)

- **Server:** EC2 `mom`, `i-02b2026cb5aec4329`, t4g.small, Ubuntu 24.04 ARM,
  private address 172.30.2.115, key `~/.ssh/mom.pem`, security group `mom`
  (`sg-05c15f95d565f3965`: 4400 from the load balancer, 22 from the admin
  address), IAM role `mom-ec2` (read `/mom/*` in SSM only).
- **Erlang and Elixir:** Hex's prebuilt builds in `/opt/erlang` (OTP
  28.5.0.8) and `/opt/elixir` (1.19.7), checked against their published
  SHA-256.
- **Deploy:** `infra/deploy.sh` (rsync, build on the server, restart);
  `SYNC_UNIT=1` also installs `infra/mom.service` and `infra/fetch-env.sh`,
  which writes `/opt/mom-env/.env` from SSM `/mom/*` at each start. Data
  (tokens) in `/var/lib/mom`.
- **Settings in SSM `/mom/*`:** `MOM_TARGETS`, `MOM_TARGET_COOKIE_SCHOOL`,
  `MOM_TARGET_COOKIE_LATTE`, `RELEASE_*`, `MOM_PORT`, `MOM_DATA_DIR`,
  `MOM_TRUST_PROXY`, and three toolchain overrides
  (`MOM_TOOLCHAIN_OTP_VERSION_OVERRIDE=28.0.2`,
  `MOM_TOOLCHAIN_ELIXIR_VERSION_OVERRIDE=1.19.4`,
  `MOM_TOOLCHAIN_NODE_VERSION_OVERRIDE=22.0.0`). `Mom.Config` pins exact
  versions for reproducible fixes; with triage `off` nothing is built, so the
  pins are overridden. Before a target uses `report` or `fix`, install the
  pinned toolchain or relax the pins.
- **Apps:** School (`school@172.30.2.137`) and Latte (`latte@172.30.2.120`)
  run named nodes with distribution on 9100 to 9105, cookies from their own
  SSM settings, and `:mom_info`; their security groups accept 4369 and 9100
  to 9105 from `mom` only.
- **Endpoint:** load balancer `ttr-lb`, rule 13, host `mom.reviveschool.org`,
  target group `mom-tg` (port 4400, health `/health`). DNS: a CNAME at GoDaddy
  to `ttr-lb-1667854674.us-east-1.elb.amazonaws.com`.
