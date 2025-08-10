# Guardium External S-TAP Test with Mock Collector

This guide walks you through deploying **Guardium External S-TAP** in OpenShift with a **dummy Postgres database**, a **mock collector**, and running smoke/load tests to validate the setup.

---

## 1. Prerequisites

- OpenShift CLI (`oc`) installed and logged in.
- Helm CLI installed.
- Namespace (`bank-test` in this example) created or will be created automatically.

---

## 2. Setup Environment Variables

```bash
NS=bank-test
SA=estap
```

---

## 3. Create Namespace & ServiceAccount

```bash
# Create namespace if it doesn't exist, otherwise switch to it
oc new-project "$NS" 2>/dev/null || oc project "$NS"

# Create the ServiceAccount used by the workload
oc -n "$NS" create sa "$SA"

# (Optional) Verify ServiceAccount
oc -n "$NS" get sa "$SA"
```

---

## 4. Deploy Dummy Postgres Database

```bash
oc apply -f Postgres/postgres.yaml -n "$NS"
```

---

## 5. Patch Security Context Constraints (SCC)

> **Note:** Using `anyuid` SCC is for testing purposes only.  
> For production, create a custom SCC with minimal privileges.

```bash
oc -n "$NS" adm policy add-scc-to-user anyuid -z "$SA"
# Or alternatively:
# oc apply -f Helm-Fix/estap-uid1000-scc.yaml
```

---

## 6. Install Guardium External S-TAP

```bash
helm install   -f Guardium_External_S-TAP/charts/overrides.yaml   estap Guardium_External_S-TAP/charts/estap   --namespace "$NS"
```

---

## 7. Deploy Mock Guardium Collector Service

```bash
oc apply -f mock-guardium-collector/tcp-tap.yaml -n "$NS"
```

---

## 8. Smoke Test

```bash
oc -n "$NS" logs deploy/tcp-tap -f
```

Run a simple `SELECT now();` test through the mock tap:

```bash
oc -n "$NS" exec -it deploy/postgres -- sh -lc '
  export PGPASSWORD=testpassword
  seq 200 | xargs -n1 -P10 -I{}     psql -h tcp-tap -p 9999 -U testuser -d testdb -qAtc "SELECT now();"
'
```

---

## 9. Load Test – Table Creation & Seeding

```bash
oc -n "$NS" exec -it deploy/postgres -- sh -lc "export PGPASSWORD=testpassword;  psql -h tcp-tap -p 9999 -U testuser -d testdb -v ON_ERROR_STOP=1 -q -c \"DROP TABLE IF EXISTS loadtest;
  CREATE TABLE loadtest (
    id BIGSERIAL PRIMARY KEY,
    k INT NOT NULL,
    v TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  CREATE INDEX ON loadtest (k);
  INSERT INTO loadtest (k, v)
    SELECT s, md5(random()::text)
    FROM generate_series(1,10000) AS s;\""
```

---

## 10. Run the Load Test

```bash
oc -n "$NS" exec deploy/postgres -- sh -lc '
  export PGPASSWORD=testpassword
  seq 1000 | xargs -P20 -I{}     psql -h tcp-tap -p 9999 -U testuser -d testdb -qAtc "
    BEGIN;
      INSERT INTO loadtest(k, v)
        SELECT (random()*100000)::int, md5(random()::text) FROM generate_series(1,5);
      SELECT id FROM loadtest ORDER BY random() LIMIT 3;
      UPDATE loadtest SET v = md5(random()::text)
        WHERE id IN (SELECT id FROM loadtest ORDER BY random() LIMIT 1);
      DELETE FROM loadtest
        WHERE id IN (SELECT id FROM loadtest ORDER BY random() LIMIT 1)
          AND random() < 0.30;
    COMMIT;"
'
```

---

## 11. Validate Load Test Results

```bash
oc -n "$NS" exec deploy/postgres -- sh -lc '
  export PGPASSWORD=testpassword
  psql -h tcp-tap -p 9999 -U testuser -d testdb -qAtc "
    SELECT '\''row_count'\'', count(*) FROM loadtest;
    SELECT '\''stats'\'', n_live_tup, n_dead_tup, n_tup_ins, n_tup_upd, n_tup_del
    FROM pg_stat_user_tables WHERE relname='\''loadtest'\'';"
'
```

---

## 12. Expected Output

Example after a successful run:

```
row_count|12818
stats|12818|298|13000|600|182
```

Where:
- `n_live_tup` = current row count.
- `n_dead_tup` = deleted/updated rows awaiting vacuum.
- `n_tup_ins` = inserts count.
- `n_tup_upd` = updates count.
- `n_tup_del` = deletes count.

---
