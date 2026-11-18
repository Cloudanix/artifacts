# Wazuh Central Server on AWS EKS (customer environment)

Deploys a complete Wazuh 4.x central server into a **customer's existing AWS
VPC**: an EKS cluster with two managed node groups, the prerequisites for the
AWS Load Balancer Controller (so Kubernetes `Service type=LoadBalancer` provisions
internet-facing NLBs), the EBS CSI driver (for `gp3` persistent volumes), and a
kustomize overlay that runs 3 workers / 1 master / 3 indexers / 1 dashboard.

Agents connect to the manager over an internet-facing NLB on:
- `1514` — agent events (workers)
- `1515` — agent registration (master)
- `55000` — Wazuh API (master)

The NLBs are created by Kubernetes Services (via the AWS Load Balancer Controller),
NOT by CloudFormation. CloudFormation only builds the cluster + the IAM/OIDC/subnet
prerequisites so those Services can succeed.

## Customer prerequisites (inputs)

The customer must supply an existing VPC with:
- **2 private subnets** (in 2 different AZs) — EKS worker nodes run here. Two AZs
  is an EKS requirement.
- **2 public subnets** (in those same 2 AZs) — internet-facing NLBs are placed
  here. **Why 2?** An NLB only enables Availability Zones where it has a subnet.
  Cross-zone load balancing does **not** register targets whose AZ is not
  enabled on the NLB. With one public subnet, workers scheduled in the other
  private AZ show as `unused` ("Target is in an Availability Zone that is not
  enabled for the load balancer") and port **1514** times out. Prefer a second
  public subnet (`/28` is enough). If the customer cannot add one, pin workers
  to the public subnet's AZ (see below).
- The public subnet(s) need a route to an internet gateway; private subnets need a
  NAT gateway for outbound (image pulls).

### Single public subnet (workaround)

If the customer only has one public subnet:

1. Find its AZ: `aws ec2 describe-subnets --subnet-ids <public> --query 'Subnets[0].AvailabilityZone'`
2. In `wazuh/envs/aws-customer/wazuh-worker-resources.yaml`, uncomment the
   `affinity.nodeAffinity` block and set `topology.kubernetes.io/zone` to that AZ
   so all workers land where the NLB is enabled.
3. Optionally annotate the Services with
   `service.beta.kubernetes.io/aws-load-balancer-subnets: <public-subnet-id>`.

This is HA-weaker than two public subnets; use only when the customer cannot add
a second public subnet.

### Test/QA VPC (optional)

For QA you don't need a pre-existing VPC — `00-test-vpc.yaml` creates a throwaway
VPC (2 private + 2 public subnets, IGW, NAT, routes). Enable it by running
`deploy.sh` with `CREATE_TEST_VPC=true`, which builds the VPC first and auto-fills
the VpcId/subnet parameters. Do NOT use this for production.

> QA test VPC (`00-test-vpc.yaml`) now creates **2 public + 2 private** subnets.
> `deploy.sh` reads `PublicSubnet1Id`/`PublicSubnet2Id` (with fallback to legacy
> `PublicSubnetId` if an older stack is still up).

## Layout

```
k8s/aws-customer-wazuh/
├── README.md                       # this file
├── infra/
│   ├── 00-test-vpc.yaml            # CF: throwaway QA VPC (opt-in, CREATE_TEST_VPC=true)
│   ├── 01-eks.yaml                 # CF: EKS control plane + OIDC + cluster SG
│   ├── 02-nodegroups.yaml          # CF: 2 managed node groups (worker + general)
│   ├── 03-irsa.yaml                # CF: IRSA roles for LB Controller + EBS CSI
│   ├── 04-ecr-pull-through-cache.yaml  # CF: OPT-IN ECR pull-through cache (Option 2)
│   ├── parameters.example.json     # copy -> parameters.json and fill in
│   └── deploy.sh                   # orchestrates the 3 stacks + addons
└── wazuh/
    ├── apply.sh                    # apply default overlay, or --forward for one customer
    ├── base/                       # vendored shared Wazuh base (self-contained)
    └── envs/
        ├── aws-customer/           # default kustomize overlay (no archive forward)
        └── aws-customer-forward/   # OPT-IN overlay: rsyslog UDP/514 from workers
```

## Deploy order

```bash
cd k8s/aws-customer-wazuh/infra

# 1. Fill in the customer inputs
cp parameters.example.json parameters.json
$EDITOR parameters.json          # VpcId, PrivateSubnetIds, PublicSubnetIds, region, etc.

# 2. Provision EKS + node groups + IAM/OIDC/EBS CSI/LB Controller
./deploy.sh                      # idempotent; creates/updates the CF stacks in order

# 3. Deploy Wazuh (no archive forwarding)
cd ../wazuh
./apply.sh
# equivalent: kubectl apply -k envs/aws-customer

# Optional: pin registry + tags without editing kustomization.yml
./apply.sh --image-registry ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com --image-tag v0.2.5

# 4. Get the agent-facing endpoints (NLB DNS names)
kubectl -n wazuh get svc wazuh wazuh-workers -o wide
```

## Notes

- `deploy.sh` tags the public subnets `kubernetes.io/role/elb=1` and the private
  subnets `kubernetes.io/role/internal-elb=1` and
  `kubernetes.io/cluster/<cluster>=shared`, which the AWS Load Balancer Controller
  requires for subnet auto-discovery.
- Storage is `gp3` via the EBS CSI driver (`ebs.csi.aws.com`), `reclaimPolicy:
  Retain` so PVCs deleted by accident don't destroy data.
- Node groups: `worker-ng` is tainted `workload=wazuh-worker:NoSchedule` so only
  the tainted+tolerating worker pods land there; everything else (indexer, master,
  dashboard) runs on `general-ng`.
- This provisions the central server only. Customer-side agent onboarding and any
  cross-account secret wiring are handled separately.

## Empty-PVC bootstrap (why the initContainer exists)

`/var/ossec/{logs,etc,queue}` are PVC `subPath` mounts, so a brand-new volume
**masks** the directories baked into the image. Every gap below is fatal on first
boot; the `fix-logs-permissions` initContainer and `start-{master,worker}.sh`
create all of them, so they self-heal after a namespace/PVC wipe:

| Missing on empty PVC | Symptom |
| --- | --- |
| `etc/shared/ar.conf` | `analysisd` FATAL, no `alerts.json` |
| `etc/shared/default/agent.conf` | wazuh-db `Unable to find the id of the group 'default'` every keepalive |
| `queue/db` | wazuh-db `Unable to bind to socket 'queue/db/wdb'`, API `Error 1017` |
| `queue/fts` | `analysisd` `CRITICAL: (1260): Error initiating FTS list` |

`kubectl delete namespace wazuh` also removes the IRSA ServiceAccount that
`infra/deploy.sh` created, and the StatefulSets then fail with
`serviceaccount "wazuh-manager" not found`. `apply.sh` recreates and re-annotates
it from the `<cluster>-irsa` stack output (`--skip-sa` to opt out).

Recreating the namespace also creates **new NLB DNS names** - re-point agents at
the new `wazuh` (1515) and `wazuh-workers` (1514) endpoints.

## Container images

The Wazuh manager (master + worker) images are published by Cloudanix to **public
ECR** under account `774118602354`:

- `public.ecr.aws/cloudanix/wazuh-master-custom:v0.2.5`
- `public.ecr.aws/cloudanix/wazuh-worker-custom:v0.2.5`

Rebuild/push from `k8s/central-vm/vmscan` after changing `start-*.sh` or Dockerfiles.
Pass tags to `./apply.sh` instead of editing git:

```bash
cd k8s/central-vm/vmscan
IMAGE_TAG=v0.2.5 AWS_REGION=us-east-1 ./build-push-images.sh
IMAGE_TAG=v0.2.5 BUILD=worker ./build-push-images.sh   # worker only (rsyslog)
IMAGE_TAG=v0.2.5 BUILD=master ./build-push-images.sh

cd ../../aws-customer-wazuh/wazuh
./apply.sh --image-registry ACCOUNT.dkr.ecr.us-east-1.amazonaws.com \
  --master-tag v0.2.5 --worker-tag v0.2.5
```

`BUILD` is `both` (default), `master`, or `worker`. `PUSH_LATEST` defaults to true.

## Optional: worker archive syslog forward (specific customers only)

Default `./apply.sh` does **not** enable this. `start-worker.sh` starts rsyslogd
only if `/etc/rsyslog.d/60-wazuh-archives.conf` is mounted. Rebuild the **worker**
image once so rsyslog packages exist (`BUILD=worker`).

UDP/514 is plaintext (full archive events). Restrict receiver ingress, or treat
as test.

```bash
cd k8s/aws-customer-wazuh/wazuh
./apply.sh --forward --target 203.0.113.10 --dry-run
./apply.sh --forward --target 203.0.113.10 --port 514 \
  --image-registry ACCOUNT.dkr.ecr.us-east-1.amazonaws.com --worker-tag v0.2.5
kubectl -n wazuh rollout restart sts/wazuh-manager-worker
```

Or copy `envs/aws-customer-forward/forward.params.example` to `forward.params`
(gitignored) and run `./apply.sh --forward`. Target IP is filled at apply time
from `--target` / `TARGET_IP` — it is not committed.

Do not `kubectl apply -k envs/aws-customer-forward` until `apply.sh --forward`
has written `generated/`. To turn off: `./apply.sh` then restart workers.

Verify: `archives.json` exists, `pgrep rsyslogd`, drop-in has the target, UDP/514
egress allowed.

Public ECR images are pullable cross-account with no auth, so customer EKS nodes
can pull them directly. Two ways to feed the images into the customer account:

### Option 1: Manual sync to a customer ECR

Customer runs a one-off script to `docker pull` the Cloudanix images and
`docker push` them into a private ECR repo in their own account, then points the
kustomize `images:` override at that repo.

**Pros:** images live entirely in the customer account; works with fully private
registries.
**Cons:** manual step on every version bump; someone has to re-run the sync and
re-tag.

### Option 2: ECR Pull-Through Cache (Customer-Side)

Customer sets up a pull-through cache rule pointing to our ECR (via a public ECR
or an intermediary). Images get cached on first pull by ECS/EKS — no manual sync
needed.

**Pros:**
- Customer never runs a sync script again
- Images cached lazily on first use

**Cons:**
- Only works if we publish to ECR Public or expose via a pull-through-compatible
  upstream

Expected upstream: Cloudanix **public ECR** (account `774118602354`).

Set up (customer account, one time). CloudFormation for this rule is included in
`infra/04-ecr-pull-through-cache.yaml` (opt-in); the equivalent CLI is:

```bash
# Create a pull-through cache rule for the ECR Public upstream.
aws ecr create-pull-through-cache-rule \
  --ecr-repository-prefix ecr-public \
  --upstream-registry-url public.ecr.aws \
  --region <customer-region>
```

Then reference images through the cache prefix instead of `public.ecr.aws`
(kustomize `images:` override in `envs/aws-customer/kustomization.yml`):

```yaml
images:
  - name: public.ecr.aws/cloudanix/wazuh-master-custom
    newName: <acct>.dkr.ecr.<region>.amazonaws.com/ecr-public/cloudanix/wazuh-master-custom
    newTag: v0.2.5
  - name: public.ecr.aws/cloudanix/wazuh-worker-custom
    newName: <acct>.dkr.ecr.<region>.amazonaws.com/ecr-public/cloudanix/wazuh-worker-custom
    newTag: v0.2.5
```

On first pod schedule, EKS pulls via the cache repo; ECR fetches from the Cloudanix
public upstream and caches it. Subsequent pulls are served from the customer's ECR.
The node role needs `ecr:BatchImportUpstreamImage` / `ecr:CreateRepository` (for the
cached repo) in addition to the usual `ecr:GetDownloadUrlForLayer` /
`ecr:BatchGetImage` / `ecr:GetAuthorizationToken`.
