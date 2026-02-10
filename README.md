# demo-apis

Three tiny Node.js demo APIs that call each other for multi-hop traffic.

## Services

- `identity-api` (users) on port `3001`
- `accounts-api` (accounts/balances) on port `3002`
- `catalog-api` (products/assignments) on port `3003`

## Local run

Run each service in its own terminal:

```
cd identity-api && npm install && npm start
cd accounts-api && npm install && npm start
cd catalog-api && npm install && npm start
```

Defaults assume docker/k8s service DNS:

- `accounts-api` expects `IDENTITY_BASE_URL=http://identity-api:3001`
- `catalog-api` expects `ACCOUNTS_BASE_URL=http://accounts-api:3002`
- `accounts-api` expects `CATALOG_BASE_URL=http://catalog-api:3003`

For local dev, override with `localhost`:

```
IDENTITY_BASE_URL=http://localhost:3001 npm start
CATALOG_BASE_URL=http://localhost:3003 npm start
ACCOUNTS_BASE_URL=http://localhost:3002 npm start
```

## Happy-path demo flow

1) Create a product in catalog:

```
POST http://localhost:3003/products
{ "name": "Premium Plan", "price": 29.99, "category": "plan" }
```

2) Onboard via accounts (calls identity + catalog):

```
POST http://localhost:3002/accounts/onboard
{
  "name": "Ava",
  "email": "ava@x.com",
  "productId": "p1",
  "initialCredit": 25
}
```

## Docker

Each service has its own `Dockerfile`:

```
docker build -t identity-api:dev ./identity-api
docker build -t accounts-api:dev ./accounts-api
docker build -t catalog-api:dev ./catalog-api
```

### Docker Compose

```
docker compose up --build
```

### kind / Kubernetes

Use the scripts below for the full local k8s flow. They create the kind
cluster, install ingress-nginx, build/load images, and apply `k8s/apps.yaml`.

Quick start:

```
./run-demo.sh
```

Then hit ingress endpoints:

```
curl -i http://localhost/identity/health
curl -i http://localhost/accounts/health
curl -i http://localhost/catalog/health
```

#### `run-demo.sh` (no Insights)

```
./run-demo.sh
```

Optional args (env vars):

- `CLUSTER_NAME` (default: `demo`)
- `IDENTITY_DIR`, `ACCOUNTS_DIR`, `CATALOG_DIR`
- `IDENTITY_IMG`, `ACCOUNTS_IMG`, `CATALOG_IMG` (default: `*:dev`)
- `FORCE_REBUILD=1` to always rebuild images

#### `run-demo-with-insights.sh`

```
export IDENTITY_PROJECT_ID="svc_xxxxxxxxxx"
export ACCOUNTS_PROJECT_ID="svc_yyyyyyyyyy"
export CATALOG_PROJECT_ID="svc_zzzzzzzzzz"
export POSTMAN_API_KEY="PMAK_xxxxxxxxxx"

./run-demo-with-insights.sh
```

Optional args (env vars):

- `CLUSTER_NAME` (default: `demo`)
- `IDENTITY_DIR`, `ACCOUNTS_DIR`, `CATALOG_DIR`
- `IDENTITY_IMG`, `ACCOUNTS_IMG`, `CATALOG_IMG`
- `FORCE_REBUILD=1`
- `KIND_CONFIG` (default: `./k8s/kind-config.yaml`)
- `APPS_YAML` (default: `k8s/apps.yaml`)
- `POSTMAN_DS_URL` (daemonset manifest URL)
- `POSTMAN_DS_LOCAL` (local path to cache manifest)
- `NS` (default: `demo`)
- `DEP_IDENTITY`, `DEP_ACCOUNTS`, `DEP_CATALOG`
- `INSIGHTS_SECRET_NAME`, `INSIGHTS_SECRET_KEY`
- `IDENTITY_PROJECT_ID`, `ACCOUNTS_PROJECT_ID`, `CATALOG_PROJECT_ID`

#### `simulate-traffic.sh`

Generates noisy demo traffic against ingress (default `http://localhost`).

```
./simulate-traffic.sh
```

Optional args:

- Flags: `-v|--verbose`, `-s|--slow` (~1 req/sec), `--show-body`
- `BASE` (default: `http://localhost`)
- Rates (percent): `BAD_REQUEST_RATE`, `ONBOARD_RATE`, `CREDIT_RATE`,
  `CREATE_PRODUCT_RATE`, `ASSIGN_PRODUCT_RATE`, `READS_RATE`
- `NO_COLOR=1` to disable ANSI colors

#### `teardown-demo.sh`

```
./teardown-demo.sh
./teardown-demo.sh --dry-run
DELETE_CLUSTER=1 ./teardown-demo.sh
```

Optional args:

- `CLUSTER_NAME` (default: `demo`)
- `APPS_YAML` (default: `k8s/apps.yaml`)
- `POSTMAN_DS_LOCAL` (default: `k8s/postman-insights-agent-daemonset.yaml`)
- `DEMO_NS` (default: `demo`)
- `POSTMAN_NS` (default: `postman-insights-namespace`)
- `INSIGHTS_SECRET_NAME` (default: `postman-insights-secret`)
- `POSTMAN_VARIANTS=1` and `VARIANT_NS_PREFIX` (default: `postman-insights-`)