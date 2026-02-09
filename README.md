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

Create Kind cluster
```
kind create cluster --name demo --config kind-config.yaml
kubectl cluster-info --context kind-demo
```

Add NGINX ingress controller
```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s
```

Build images, load into kind, then apply manifests:

```
docker build -t identity-api:dev ./identity-api
docker build -t accounts-api:dev ./accounts-api
docker build -t catalog-api:dev ./catalog-api

kind load docker-image identity-api:dev --name identity
kind load docker-image accounts-api:dev --name accounts
kind load docker-image catalog-api:dev --name catalog

kubectl apply -f apps.yaml
kubectl -n demo get pods,svc,ingress
```

Healthcheck on services
```
curl -i http://localhost/identity/health
curl -i http://localhost/accounts/health
curl -i http://localhost/catalog/health
```