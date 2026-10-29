# cdx-sql mode (Azure) — UNTESTED, written 30 Oct 2026

cdx-sql is a Go proxy that replaces ProxySQL in the same slot: same ports (6032 admin,
6033 MySQL, 6133 Postgres), same data folder `/var/lib/proxysql`, same uid 1000. Grants and
Postgres cancel keys live in the local Postgres (`jitdb`), so several cdx-sql container groups
can run behind one internal load balancer, and any group may receive any connection.

Nothing here has been run against a real subscription yet. With `PROXY_ENGINE` unset (or
`proxysql`) the scripts make exactly the same `az` calls as before (checked with a stub `az`).

## Settings (environment variables, no new prompts)

| Setting | Default | Read by | Meaning |
|---|---|---|---|
| `PROXY_ENGINE` | `proxysql` | 1, 3 | `cdxsql` turns cdx-sql mode on. Anything else stops the script. |
| `CDXSQL_REPLICAS` | `2` | 3 | Number of cdx-sql container groups (at least 1). |
| `CDXSQL_LB_NAME` | `cdxsql-ilb` | 3 | Name of the internal load balancer. |
| `CDXSQL_LB_SUBNET_PREFIX` | `10.0.8.0/24` | 3 | New subnet `cdxsql-lb-subnet` for the LB frontend; must be free and inside the VNet (default VNet `10.0.0.0/16`). |
| `CDXSQL_LB_IP` | `10.0.8.5` | 3 | Static private IP of the LB frontend, inside that subnet. |

## Turning it on

```bash
PROXY_ENGINE=cdxsql ./1.sync-acr.sh
PROXY_ENGINE=cdxsql CDXSQL_REPLICAS=2 ./3.deploy-aci.sh
```

`2.setup-infra.sh` is unchanged. `3.deploy-aci.sh` already deletes and recreates every group,
so the same command switches an existing install.

## Why the LB frontend is not 10.0.6.5

`aci-subnet` is delegated to `Microsoft.ContainerInstance/containerGroups`; Azure allows only
container groups in it, so an LB frontend there fails. The frontend gets its own subnet, and
the script repoints the two places that used 10.0.6.5 for the proxy:
- the jump box socat units `socat-proxysql-psql` (6133) and `socat-proxysql-mysql` (6033),
  rewritten with `az vm run-command` (developers' `ssh -L` is unchanged);
- proxyserver's `PROXYSQL_HOST` env var (these scripts pass the host as an env var; there is
  no `PROXYSQL-HOST` Key Vault secret).

HAProxy on the jump box was the fallback; a Standard LB was kept because the ACI docs
describe ACI groups as LB backends (IP-based pool, `subnet` given per address) and it keeps the
jump box out of proxyserver's admin path. Note the Load Balancer docs still list "IP-based
backend pools don't support ACI containers"; if the pool update is refused, that is why.

## IP scheme

ACI cannot be given a private IP; the script relies on creation order, as before:
postgresql .4, `proxysql` (first cdx-sql group) .5, proxyserver .6, query-logging .7,
dam-server .8, then extra groups `proxysql-2` … `proxysql-N`, created last, normally .9, .10, ….
The LB pool is set from the IPs Azure actually returns, so a shifted IP is still correct.
`query-logging` and `dam-server` keep `PROXYSQL_HOST` = the first group's IP.

## What it creates or changes (resource group from `~/jit-infra.env`)

| Resource | Change |
|---|---|
| ACR | `1` also imports `cloudanix/ecr-aws-jit-cdx-sql`. |
| Key Vault secret `CDXSQL-ADMIN-TOKEN` | New (`openssl rand -hex 32`), reused if it exists. `3` grants you "Key Vault Secrets Officer" for a moment to read it and `POSTGRES-PASSWORD` (same pattern as `2`), then removes that role unless you already had it. |
| Container groups `proxysql`, `proxysql-2..N` | cdx-sql image, ports 6032/6033/6133, 0.5 CPU / 1 GB, share `proxysql-data` (Azure Files, mountable by several groups) at `/var/lib/proxysql`, env `CDXSQL_GRANTS_DSN=postgres://pgjitdbuser@<postgresql IP>:5432/jitdb?sslmode=disable`, secure env `CDXSQL_ADMIN_TOKEN`, `PGPASSWORD`. |
| Subnet `cdxsql-lb-subnet`, LB `cdxsql-ilb` | Standard internal LB, frontend `cdxsql-frontend` at `CDXSQL_LB_IP`, IP-based pool `cdxsql-pool`, TCP probe `cdxsql-tcp-6133` (port 6133, every 5 s), rules `cdxsql-6032/6033/6133` with idle timeout 30 min and TCP reset (Azure's 4-minute default would cut idle IDE sessions; sessions idle over 30 min are still reset). |
| Container group `proxyserver` | `PROXYSQL_HOST=CDXSQL_LB_IP`, env `CDX_PROXY_ENGINE=cdxsql`, secure env `CDXSQL_ADMIN_TOKEN`. |
| Jump box | socat 6133/6033 forward to `CDXSQL_LB_IP`. |

query-logging stays one group, so there is one log shipper.

## Untested / assumptions

- Developers need a cdx CLI that sends the grant id (PROXY protocol v2 header) on every
  connection; cdx-sql refuses connections without it.
- The synced `ecr-aws-jit-proxy-server:latest` must be built from cdx-jit-server code that knows
  `CDX_PROXY_ENGINE=cdxsql`.
- `cloudanix/ecr-aws-jit-cdx-sql` must exist in Cloudanix's ACR `cdxjitacr111`; CI only pushes
  it to ECR today.
- ACI has no CLI health probe; the LB's TCP probe on 6133 decides which groups get traffic.
- uid 1000 writing to the Azure Files mount, the LB with ACI backends, and RBAC propagation
  time (the script retries for 3 minutes) are all untried.
- `az ad signed-in-user show` needs a user login (not a service principal), as in `2`.
- Rollback: `./3.deploy-aci.sh` without `PROXY_ENGINE`, then
  `az container delete -g <rg> -n proxysql-2 --yes` (and each further extra),
  repoint socat: `sudo sed -i -E 's#TCP:[0-9.]+:(6133|6033)$#TCP:10.0.6.5:\1#' /etc/systemd/system/socat-proxysql-{psql,mysql}.service && sudo systemctl daemon-reload && sudo systemctl restart socat-proxysql-psql socat-proxysql-mysql` on the jump box,
  and `az network lb delete -g <rg> -n cdxsql-ilb`. Grants held by cdx-sql are not copied to ProxySQL.

## Verify after running

```bash
RG=jit-db-rg; LB=cdxsql-ilb
az container list -g $RG --query "[].{name:name,state:instanceView.state,ip:ipAddress.ip}" -o table
az container logs -g $RG -n proxysql            # no "admin:" / "grantstore:" errors; same for proxysql-2..
az network lb address-pool show -g $RG --lb-name $LB -n cdxsql-pool \
  --query "loadBalancerBackendAddresses[].ipAddress" -o tsv        # the cdx-sql group IPs
az monitor metrics list --resource $(az network lb show -g $RG -n $LB --query id -o tsv) \
  --metric DipAvailability --interval PT1M -o table                # health probe status, ~100
az container show -g $RG -n proxyserver \
  --query "containers[0].environmentVariables[].{n:name,v:value}" -o table   # PROXYSQL_HOST, CDX_PROXY_ENGINE

# on the jump box
systemctl cat socat-proxysql-psql socat-proxysql-mysql | grep ExecStart   # TCP:10.0.8.5:...
nc -vz 10.0.8.5 6133; nc -vz 10.0.8.5 6033; nc -vz 10.0.8.5 6032
TOK=...   # az keyvault secret show --vault-name <kv> --name CDXSQL-ADMIN-TOKEN --query value -o tsv
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOK" \
  http://10.0.8.5:6032/v1/sessions/00000000000000000000000000000000   # 404 expected; 401 = token, 503 = Postgres

# grant store tables
az container exec -g $RG -n postgresql --exec-command "psql -U pgjitdbuser -d jitdb -c '\dt cdxsql.*'"
```

Then connect end to end with `cdx db connect`, run a query and a Ctrl-C cancel several times,
and check `queries_pgsql.log.*` files from more than one writer appear in the `proxysql-data` share.
