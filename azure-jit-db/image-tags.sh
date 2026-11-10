# Cloudanix central registry. Anonymous pull is on. Customer setup creates a
# different registry, named jitacr<suffix>, and imports from this one.
CENTRAL_ACR_NAME=cdxjitcentral
CENTRAL_ACR_SERVER=cdxjitcentral.azurecr.io

# Repository paths in the central registry. The image tag is not stored here.
# 1.sync-acr.sh asks for it and 3.deploy-aci.sh reads IMAGE_TAG from ~/jit-infra.env.
DB_PROXYSQL_REPO=cloudanix/ecr-aws-jit-proxy-sql
DB_PROXYSERVER_REPO=cloudanix/ecr-aws-jit-proxy-server
DB_QUERYLOG_REPO=cloudanix/ecr-aws-jit-query-logging
DB_DAM_REPO=cloudanix/ecr-aws-jit-dam-server
DB_POSTGRES_REPO=cloudanix/ecr-aws-jit-postgresql
