NS=bank-test

# make sure the namespace exists
oc new-project "$NS" 2>/dev/null || oc project "$NS"

# create the workload SA that your values.yaml references
oc -n "$NS" create sa estap

# (optional) verify
oc -n "$NS" get sa estap

# Create Dummy Postgres Database
oc apply -f Postgres/postgres.yaml -n "$NS" 

# Patch OCP Security requirements 
oc -n "$NS" adm policy add-scc-to-user anyuid -z "$SA"
#oc apply -f Helm-Fix/estap-uid1000-scc.yaml

# Install Guardium External S-TAP Service
helm install -f Guardium_External_S-TAP/charts/overrides.yaml estap Guardium_External_S-TAP/charts/estap --namespace "$NS"

# Deploy Mock Service
oc apply -f mock-guardium-collector/tcp-tap.yaml -n "$NS"

# Tests
oc -n "$NS" logs deploy/tcp-tap -f

# Smoke Test 
oc -n "$NS" exec -it deploy/postgres -- sh -lc '
  export PGPASSWORD=testpassword
  seq 200 | xargs -n1 -P10 -I{} psql -h tcp-tap -p 9999 -U testuser -d testdb -qAtc "SELECT now();"
'
