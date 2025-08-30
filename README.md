# Bank Test: Guardium External S‑TAP + PostgreSQL + Viewer

This repository stands up two demo “banks” on OpenShift:
- **bank-test1** and **bank-test2** each run:
  - a dummy **PostgreSQL** database
  - **Guardium External S‑TAP** via Helm (exposed on **port 8888**)
  - an optional **PostgreSQL Viewer** web app (binary build)

It also includes scripts to load test the database with `pgbench`.

---

## 📦 Repository layout

```
.
├─ Guardium_External_S-TAP/           # Helm chart + values for E‑STAP
├─ Postgres-bank-test1/postgres.yaml  # Dummy Postgres for bank-test1
├─ Postgres-bank-test2/postgres.yaml  # Dummy Postgres for bank-test2
├─ Web-App/                           # Minimal viewer (Express + pg)
│  ├─ deploy-pg-viewer.sh             # Deploy viewer via OpenShift binary build
│  └─ (server.js, Dockerfile, package.json)
├─ deploy-banks.sh                    # One-shot: Postgres + E‑STAP in both namespaces
├─ security-groups.sh                 # (optional) AWS SG helper
└─ scripts/
   └─ pg-loadtest.sh                  # pgbench wrapper (prompts for user/db)
```

---

## ✅ Prerequisites

- OpenShift cluster access with project create, build, and route permissions
- CLIs: `oc` and `helm` in $PATH
- (For load test) `pgbench` locally **or** ability to run a `postgres:16` pod
- Recommended: admin rights to grant the `anyuid` SCC to a ServiceAccount (test only)

---

## 1) Deploy the banks (Postgres + E‑STAP)

Run from the repo root:

```bash
bash deploy-banks.sh
```

What the script does (per namespace **bank-test1** and **bank-test2**):
1. Ensures the project exists and creates a ServiceAccount **estap**.
2. Applies the dummy **Postgres** manifest `Postgres-<ns>/postgres.yaml` and waits for `deploy/postgres` to roll out.
3. Grants the **anyuid** SCC to the **estap** ServiceAccount (TEST ONLY).
4. Installs/Upgrades the **Guardium External S‑TAP** Helm chart using values at `Guardium_External_S-TAP/charts/<ns>.yaml`.
5. Locates the **LoadBalancer** service that exposes **port 8888**, waits for the external hostname/IP, and prints it.

You should see output similar to:

```
==> Project: bank-test1
==> Apply Postgres: Postgres-bank-test1/postgres.yaml
==> Wait for deploy/postgres
...
==> Install/upgrade E-STAP in bank-test1 (release=estap-bank1)
==> Wait for deploy/estap-bank1-estap
    LB service: estap-bank1-estap-lb
    External endpoint: a2cfe8d7fe55c4…elb.ap-southeast-2.amazonaws.com:8888
```

> If the LB endpoint is not ready yet, the script prints a WARN and how to check again with `oc`.

---

## 2) Deploy the PostgreSQL Viewer (per bank)

From the repo root, run for each namespace you want to expose the viewer in:

```bash
bash Web-App/deploy-pg-viewer.sh <namespace> ./Web-App
# e.g.
bash Web-App/deploy-pg-viewer.sh bank-test1 ./Web-App
bash Web-App/deploy-pg-viewer.sh bank-test2 ./Web-App
```

What the script does:
- Performs a **binary build** from `./Web-App` and creates/updates ImageStream, Deployment, Service and Route with the name **pg-viewer-single** (listening on **8080**).
- **Discovers the E‑STAP LoadBalancer service** on port **8888** in the namespace and resolves its external **hostname/IP** (sets this as `PGHOST`).
- Reads **`POSTGRES_USER`**, **`POSTGRES_DB`**, **`POSTGRES_PASSWORD`** directly from `deploy/postgres` env to set `PGUSER`, `PGDATABASE`, `PGPASSWORD`.  
  (Includes fallbacks for non‑index‑0 env arrays.)
- Sets the viewer deployment env:
  - `PGHOST=<E‑STAP LB hostname/IP>`
  - `PGPORT=8888`
  - `PGUSER=<from deploy/postgres>`
  - `PGPASSWORD=<from deploy/postgres>`
  - `PGDATABASE=<from deploy/postgres>`
- Waits for rollout and prints the public **Route URL** and the connection target.

After a successful run you’ll see something like:

```
✅ Viewer ready:
  Route: http://pg-viewer-single-<ns>.apps.<cluster-domain>
  Will connect to a2cfe8d7fe55c4578…elb.ap-southeast-2.amazonaws.com:8888, DB testdb1 as testuser1
```

> If you redeploy UI changes, you can trigger a fresh binary build with:
> ```bash
> oc -n <ns> start-build pg-viewer-single --from-dir=./Web-App --follow
> oc -n <ns> rollout restart deploy/pg-viewer-single
> ```

---

## 3) (Optional) Database load test with `pgbench`

A helper script is provided that **prompts only for user & database**, and can scrape host/port from the Viewer page:

```bash
# Discover host/port from the viewer route, then prompt for PGUSER/PGDATABASE
bash scripts/pg-loadtest.sh --viewer "http://pg-viewer-single-<ns>.apps.<cluster>/"
  -T 60 -c 40 -j 4
```

- **PGHOST/PGPORT**: extracted from the Viewer HTML (port 8888).
- **PGUSER/PGDATABASE**: prompted (defaults prefilled if the page shows them).
- **PGPASSWORD**: taken from `$PGPASSWORD` or `~/.pgpass` automatically (no prompt).

More examples:
```bash
# Read-only (select-only) 60s
bash scripts/pg-loadtest.sh --viewer "http://<route>/" -T 60 -c 80 -j 4 -S

# DSN (skips prompts)
bash scripts/pg-loadtest.sh --dsn "postgres://u:pw@host:8888/db" -T 30 -c 50
```

> First time only, initialize pgbench tables: `bash scripts/pg-loadtest.sh --initialize -s 10 -T 60 -c 40`

---

## 🔧 Troubleshooting

- **LB not ready**: Check the service again:
  ```bash
  oc -n <ns> get svc <release>-estap-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"
"}{.status.loadBalancer.ingress[0].ip}{"
"}'
  ```
- **Viewer shows old UI**: Rebuild from directory and restart:
  ```bash
  oc -n <ns> start-build pg-viewer-single --from-dir=./Web-App --follow
  oc -n <ns> rollout restart deploy/pg-viewer-single
  ```
- **pgbench not installed**: Run it inside the cluster:
  ```bash
  oc run -it --rm pgbench --image=postgres:16 -- bash -lc 'pgbench --version'
  ```

---

## ⚠️ Security notes

- `deploy-banks.sh` grants **anyuid** SCC to the E‑STAP ServiceAccount for convenience in **test** environments. Do not use this pattern in production.
- The viewer is stateless and reads DB credentials from env vars; manage secrets appropriately in real deployments.

---

## 🧹 Cleanup

Delete the two demo projects:

```bash
oc delete project bank-test1 bank-test2
```
