oc apply -f tcp-tap.yaml
oc -n bank-test logs deploy/tcp-tap -f &
oc -n bank-test exec -it deploy/postgres -- sh -lc '
  export PGPASSWORD=testpassword
  seq 200 | xargs -n1 -P10 -I{} psql -h tcp-tap -p 9999 -U testuser -d testdb -qAtc "SELECT now();"
'
