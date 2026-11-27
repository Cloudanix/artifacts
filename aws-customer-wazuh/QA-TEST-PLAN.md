# QA test plan - Wazuh on EKS (AWS customer template)

Step-by-step validation of the CloudFormation infra + kustomize overlay in a
sandbox / QA AWS account. Follow top to bottom; each phase has a pass criterion.

## 0. Prerequisites (on your workstation)

```bash
aws --version          # v2
kubectl version --client
helm version
jq --version
cfn-lint --version     # optional but recommended
```

QA account inputs you must have ready:
- A VPC id
- 2 private subnets (2 AZs) + 2 public subnets (2 AZs) in that VPC
- The public subnets must have a route to an internet gateway (for the NLBs)
- Credentials for the QA account with rights to create EKS/IAM/EC2/SecretsManager

```bash
export AWS_REGION=us-east-1            # your QA region
export AWS_PROFILE=qa                  # your QA profile
aws sts get-caller-identity            # confirm you are in the QA account
```

## 1. Static validation (no AWS calls)

```bash
cd k8s/aws-customer-wazuh
cfn-lint infra/*.yaml                                  # want: no output (clean)
kubectl kustomize wazuh/envs/aws-customer >/dev/null && echo "kustomize OK"
```
**Pass:** cfn-lint clean, kustomize builds.

## 2. Server-side template validation (needs creds)

```bash
for f in infra/01-eks.yaml infra/02-nodegroups.yaml infra/03-irsa.yaml; do
  echo "== $f =="; aws cloudformation validate-template --template-body "file://$f" >/dev/null \
    && echo OK || echo FAILED
done
```
**Pass:** all three return OK. (This is the step cfn-lint cannot do — it confirms
AWS actually accepts the templates.)

## 3. Fill parameters + deploy infra

```bash
cd infra
cp parameters.example.json parameters.json
# edit: SecretName, SecretValue, sizing.
# For QA you can let deploy.sh create the VPC (below), so VpcId/subnets in
# parameters.json are ignored when CREATE_TEST_VPC=true.
$EDITOR parameters.json

# QA: create a throwaway VPC (2 private + 1 public subnet) and deploy everything:
CREATE_TEST_VPC=true ./deploy.sh

# Production (customer VPC): fill VpcId/PrivateSubnetIds/PublicSubnetIds and run:
#   ./deploy.sh
```
`deploy.sh` (with CREATE_TEST_VPC=true) creates the test VPC first, then runs the
3 CF stacks, tags subnets, installs EBS CSI + LB Controller, creates the
wazuh-manager IRSA SA, and prints the secret ARN + role ARN.

Confirm the test VPC (QA only):
```bash
aws cloudformation describe-stacks --stack-name wazuh-test-vpc \
  --query "Stacks[0].Outputs" --output table
```

**Pass:** script finishes without error and prints the "Infra ready" banner.

Verify the stacks + cluster:
```bash
aws cloudformation describe-stacks \
  --query "Stacks[?starts_with(StackName,'wazuh')].{n:StackName,s:StackStatus}" --output table
# all CREATE_COMPLETE / UPDATE_COMPLETE

aws eks describe-cluster --name wazuh --query 'cluster.status'   # ACTIVE
kubectl get nodes -L workload
# want: 3 general-ng nodes (workload=general) + 2 worker-ng (workload=wazuh-worker)
```

## 4. Verify prerequisites the LB Controller needs

```bash
# LB Controller running
kubectl -n kube-system get deploy aws-load-balancer-controller
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=20 | grep -i error || echo "no errors"

# EBS CSI addon active
aws eks describe-addon --cluster-name wazuh --addon-name aws-ebs-csi-driver \
  --query 'addon.status'    # ACTIVE

# Subnet tags applied
aws ec2 describe-subnets --subnet-ids <public-subnet-id> \
  --query 'Subnets[0].Tags'    # expect kubernetes.io/role/elb=1

# IRSA SA annotated
kubectl -n wazuh get sa wazuh-manager -o jsonpath='{.metadata.annotations}'; echo
# expect eks.amazonaws.com/role-arn=arn:aws:iam::...:role/wazuh-wazuh-manager-role
```
**Pass:** LB Controller has no error logs, EBS CSI ACTIVE, subnets tagged, SA annotated.

## 5. Deploy Wazuh

```bash
cd ../wazuh
kubectl kustomize envs/aws-customer | less     # final review
kubectl apply -k envs/aws-customer

kubectl -n wazuh get pods -w
```
**Pass (wait ~5-10 min):**
- `wazuh-indexer-0/1/2` 1/1 (one per general node)
- `wazuh-manager-master-0` 1/1
- `wazuh-manager-worker-0/1/2` 1/1 (on worker-ng)
- `wazuh-dashboard-*` 1/1

Check placement + PVCs:
```bash
kubectl -n wazuh get pods -o wide | awk '{print $1, $7}'   # workers on worker-ng, rest general
kubectl -n wazuh get pvc                                   # all Bound on wazuh-storage (gp3)
```

## 6. Verify NLBs provisioned

```bash
kubectl -n wazuh get svc wazuh wazuh-workers -o wide
# EXTERNAL-IP becomes an *.elb.amazonaws.com NLB DNS name for each (may take 2-3 min)

# Confirm they are internet-facing NLBs in AWS
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?Type=='network'].{Name:LoadBalancerName,Scheme:Scheme,DNS:DNSName}" --output table
# Scheme = internet-facing
```
**Pass:** both services get NLB DNS names; AWS shows them as internet-facing network LBs
serving 1515+55000 (wazuh) and 1514 (wazuh-workers).

## 7. Cluster + indexer health

```bash
# Wazuh cluster: master + 3 workers
kubectl -n wazuh exec wazuh-manager-master-0 -c wazuh-manager -- \
  /var/ossec/bin/cluster_control -l

# Indexer cluster green, 3 nodes
kubectl -n wazuh exec wazuh-indexer-0 -- \
  curl -sk -u admin:<indexer-pass> 'https://localhost:9200/_cluster/health?pretty' \
  | grep -E 'status|number_of_nodes'

# Filebeat -> indexer
kubectl -n wazuh exec wazuh-manager-master-0 -c wazuh-manager -- filebeat test output
```
**Pass:** master + 3 workers listed; indexer status green with 3 nodes; filebeat "talk to server... OK".

## 8. Verify Secrets Manager access via IRSA (the new bit)

```bash
# The secret exists with your initial value
aws secretsmanager get-secret-value --secret-id cdx-central-vm-auth-tokens \
  --query SecretString --output text

# The manager pod can read it through IRSA (run the integration as the wazuh user)
kubectl -n wazuh exec wazuh-manager-master-0 -c wazuh-manager -- \
  python3 -c "import boto3,os; \
    print(boto3.client('secretsmanager').get_secret_value(SecretId='cdx-central-vm-auth-tokens')['SecretString'])"
```
**Pass:** the pod prints the secret JSON with NO `AccessDenied` / `403`. This proves the
IRSA role + trust + policy are wired correctly (the exact failure mode we hit on GKE).

Update the secret later (adds/rotates tokens without redeploy):
```bash
aws secretsmanager put-secret-value --secret-id cdx-central-vm-auth-tokens \
  --secret-string '{"workspace_abc":"token1","workspace_def":"token2"}'
```

## 9. Verify crons run as the wazuh user (the GKE failure class)

```bash
# crond alive
kubectl -n wazuh exec wazuh-manager-master-0 -c wazuh-manager -- pgrep -a crond

# run push-alerts as the pure wazuh user (uid 999, no supplementary groups) - must be clean
kubectl -n wazuh exec wazuh-manager-master-0 -c wazuh-manager -- python3 -c "
import os,subprocess
os.setgroups([999]); os.setgid(999); os.setuid(999); os.environ['HOME']='/var/ossec'
r=subprocess.run(['/usr/bin/python3','/var/ossec/integrations/cloudanix-push-alerts.py'],
                 capture_output=True,text=True,timeout=60)
bad=[l for l in (r.stdout+r.stderr).splitlines() if 'Permission' in l or 'AccessDenied' in l]
print('exit',r.returncode,'->', 'DENIED: '+bad[-1] if bad else 'clean')
"
```
**Pass:** exit 0, "clean" (no permission errors reading scripts/logs/state or the secret).

## 10. Agent smoke test (optional, end-to-end)

Point one throwaway agent at the manager NLBs:
```
# agent ossec.conf:
#   <client><server><address><wazuh-workers NLB DNS></address><port>1514</port></server></client>
# register against the wazuh NLB DNS on 1515, then start the agent
```
```bash
kubectl -n wazuh exec wazuh-manager-master-0 -c wazuh-manager -- /var/ossec/bin/agent_control -l
# agent shows Active

kubectl -n wazuh exec wazuh-indexer-0 -- \
  curl -sk -u admin:<indexer-pass> '/_cat/indices/wazuh-alerts-*?v'
# alerts indexing
```
**Pass:** agent Active, alerts landing in the indexer, visible in the dashboard.

## 11. Teardown (QA cleanup)

Preferred (waits for each stack, drops NLBs first, force-deletes the secret + leftover Retain EBS). **Keeps `wazuh-test-vpc`** so NAT/subnets stay; pass `DELETE_TEST_VPC=true` only for a full nuke.

```bash
export AWS_REGION=us-east-1
cd k8s/aws-customer-wazuh/infra
./cleanup.sh
CREATE_TEST_VPC=true ./deploy.sh
```

Manual equivalent:

```bash
# Wazuh workloads (PVCs are Retain -> PVs/EBS volumes survive; delete them too if desired)
kubectl delete -k wazuh/envs/aws-customer

# Delete leftover EBS volumes from the Retain PVs, then the stacks (reverse order)
aws cloudformation delete-stack --stack-name wazuh-irsa
aws cloudformation delete-stack --stack-name wazuh-nodegroups
aws cloudformation delete-stack --stack-name wazuh-eks
# QA only: delete the test VPC last (after the cluster is gone)
aws cloudformation delete-stack --stack-name wazuh-test-vpc
# NOTE: the Secrets Manager secret has a recovery window; force-delete if re-testing soon:
aws secretsmanager delete-secret --secret-id cdx-central-vm-auth-tokens \
  --force-delete-without-recovery
```

## Known gaps to check during QA

- **Manager image**: the overlay pulls the cloudanix ECR image. In the QA account
  confirm image pull works (grant cross-account ECR pull or push a copy). A pod
  stuck `ImagePullBackOff` = this.
- **Secrets/certs**: base ships placeholder certs + default passwords. For a real
  customer, regenerate the indexer/dashboard certs and rotate the default creds.
- **EKS version / AMI**: if `01-eks.yaml` version (1.31) or the AL2023 AMI type is
  unavailable in the QA region, stack 01/02 fails fast — adjust KubernetesVersion.
