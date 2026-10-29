# cdx-sql mode (GCP) — UNTESTED, written 30 Oct 2026

cdx-sql is a Go proxy that replaces ProxySQL in the same slot: same ports (6032 admin,
6033 MySQL, 6133 Postgres), same data folder `/var/lib/proxysql`, same uid 1000. Grants live
in the local Postgres (`jitdb`), so several cdx-sql pods can run behind the existing
`proxysql-ilb` internal load balancer. Postgres cancel keys are shared between pods through
the same database, so a per-connection load balancer is fine.

Nothing here has been run against a real project yet. With `PROXY_ENGINE` unset (or
`proxysql`) every script does exactly what it did before; the generated
`jit-service-manifest.yaml` was checked to be byte-for-byte identical.

## Settings

| Setting | Default | Read by | Meaning |
|---|---|---|---|
| `PROXY_ENGINE` | `proxysql` | 03, 04, 06 | `cdxsql` turns cdx-sql mode on. Anything else stops the script. |
| `CDXSQL_REPLICAS` | `2` | 04, 06 | Number of cdx-sql pods (whole number, at least 1). |

Both are environment variables (no new prompts). `04` writes them into `/tmp/jit-config.env`
only in cdx-sql mode; `06` reads them from that file or from its own environment.

## Turning it on

New install:

```bash
PROXY_ENGINE=cdxsql ./03-sync-artifact-registry.sh
PROXY_ENGINE=cdxsql CDXSQL_REPLICAS=2 ./04-setup-infrastructure.sh
./05-upload-config-bastion.sh
# on the bastion:
./06-identity-and-workloads-setup.sh
```

Existing install: sync the image with `PROXY_ENGINE=cdxsql ./03-sync-artifact-registry.sh`,
then on the bastion run `PROXY_ENGINE=cdxsql CDXSQL_REPLICAS=2 ./06-identity-and-workloads-setup.sh`.
Do **not** re-run `04` on an existing install: it generates a new `POSTGRES_PASSWORD` and adds
it to Secret Manager (existing behaviour, not cdx-sql specific), which no longer matches the
already-initialised Postgres.

## What it creates or changes (namespace `jit-services`)

| Resource | Change in cdx-sql mode |
|---|---|
| Artifact Registry | `03` also syncs `gcp-ar-jit-cdx-sql` from Cloudanix's registry. |
| Secret `cdxsql-admin-token` | New. Key `CDXSQL_ADMIN_TOKEN` = `openssl rand -hex 32`, created once; an existing one is reused. |
| Deployment `proxysql` | Image `gcp-ar-jit-cdx-sql:latest`; `replicas: CDXSQL_REPLICAS`; extra init container `load-secrets` (runs as root, writes only `PGPASSWORD` from `POSTGRES_PASSWORD` in the Secret Manager secret); command sources it and starts `/usr/local/bin/cdxsql-entrypoint`; env `CDXSQL_GRANTS_DSN=postgres://pgjitdbuser@postgresql:5432/jitdb?sslmode=disable` and `CDXSQL_ADMIN_TOKEN` (from the Secret); readiness and liveness probes `cdxsql -config /etc/cdxsql/config.json -healthcheck`. Name, labels, uid 1000, `fix-permissions` init container and volumes are unchanged, so `proxysql-ilb`, the `proxysql` ClusterIP service and the jump VM socat keep working. |
| Deployment `proxyserver` | Env `CDX_PROXY_ENGINE=cdxsql` and `CDXSQL_ADMIN_TOKEN` (same Secret). It still reaches the admin port through the `proxysql` service (6032), which spreads calls over the pods. |
| Deployment `query-logging` | `strategy: Recreate`, so there is never more than one shipper, also during a rollout. |

Not changed: services, ILBs, jump VM, NFS server, PV/PVC. Shared storage is already
ReadWriteMany: the `proxysql-pvc` claim is backed by the NFS server VM that `04` creates, so
every cdx-sql pod, proxy-server and query-logging mount the same `/var/lib/proxysql`.
Filestore is not needed and is not enabled.

## Untested / assumptions

- Developers need a cdx CLI that sends the grant id (PROXY protocol v2 header) on every
  connection; cdx-sql refuses connections without it.
- The synced `gcp-ar-jit-proxy-server:latest` must be built from cdx-jit-server code that knows
  `CDX_PROXY_ENGINE=cdxsql`.
- During the switch the `proxysql` Deployment rolls, so for a minute or two `proxysql-ilb` may
  reach a mix of ProxySQL and cdx-sql pods.
- The image `gcp-ar-jit-cdx-sql` must exist in `us-central1-docker.pkg.dev/cloudanix-app/cdx-jit-db-artifacts`.
  CI (`jit-db-images.yml`) only pushes `jit-cdx-sql` to ECR today; someone has to mirror it.
- `load-secrets` needs root (`apk add jq`) while the pod runs as uid 1000; it sets
  `runAsUser: 0` for that container only.
- The probe needs only the config file (it calls cdx-sql's `health_listen`, `127.0.0.1:6135`).
- Several writers on the small NFS VM (e2-micro) have not been load-tested.
- `09-patch-proxysql.sh` patches containers by name and should keep working; not tried.
- Switching back: run `06` without `PROXY_ENGINE` (and remove the two lines from
  `/tmp/jit-config.env`). Grants held by cdx-sql are not copied to ProxySQL; open sessions end.

## Verify after running

```bash
NS=jit-services
kubectl -n $NS get deploy proxysql proxyserver query-logging
kubectl -n $NS get pods -l app=proxysql -o wide            # CDXSQL_REPLICAS pods, all READY 1/1
kubectl -n $NS logs -l app=proxysql --tail=50              # no "admin:" / "grantstore:" errors
kubectl -n $NS get endpoints proxysql-ilb                  # one address per pod
kubectl -n $NS get deploy query-logging -o jsonpath='{.spec.strategy.type}{"\n"}'   # Recreate
kubectl -n $NS exec deploy/proxyserver -- printenv CDX_PROXY_ENGINE                 # cdxsql

# grant store tables created by cdx-sql
kubectl -n $NS exec postgresql-0 -- psql -U pgjitdbuser -d jitdb -c '\dt cdxsql.*'

# admin API with the shared token: an unknown grant should give 404; 401 = token mismatch, 503 = Postgres
TOK=$(kubectl -n $NS get secret cdxsql-admin-token -o jsonpath='{.data.CDXSQL_ADMIN_TOKEN}' | base64 -d)
kubectl -n $NS run cdxsql-check --rm -i --restart=Never --image=curlimages/curl -- \
  -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOK" \
  http://proxysql:6032/v1/sessions/00000000000000000000000000000000

# query logs from every pod land in the shared folder
kubectl -n $NS exec deploy/query-logging -- sh -c 'ls /var/lib/proxysql | grep queries_'
```

Then connect end to end with `cdx db connect` as usual, run a query and a Ctrl-C cancel a few
times (cancels should work whichever pod the ILB picks).
