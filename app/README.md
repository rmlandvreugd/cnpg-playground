# demo-app

Litestar application backed by a CNPG PostgreSQL cluster in `kind-k8s-local`.

## Local in-cluster development with Tilt

### Prerequisites

The following platform components must already be running in `kind-k8s-local`:
Traefik, cert-manager, External Secrets Operator, Vault, and the CNPG operator.

### One-time setup

```bash
cd app
./scripts/setup.sh            # DB only: demo-db cluster + inline pooler + ESO + traefik-dev LB
# ./scripts/setup.sh --with-app   # ALSO install the prod app into the `demo` namespace
```

`setup.sh` prints the dev Traefik IP and the exact `export TRAEFIK_IP_DASHED=…` line to use next.

You can also set `INSTALL_APP=1` instead of `--with-app`:

```bash
INSTALL_APP=1 ./scripts/setup.sh
```

### Start live development

```bash
cd app
export TRAEFIK_IP_DASHED=$(kubectl get svc -n traefik traefik-dev \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | tr '.' '-')
tilt up                       # Tilt UI at http://localhost:10350
```

Tilt builds the dev image from `Dockerfile.dev`, deploys the chart into `demo-dev`
(`--reload` on, `dev` schema), runs startup migrations, and port-forwards the pod.

### Accessing the app

| Surface | URL |
|---------|-----|
| Ingress (dev LB) | `https://demo-dev-demo.<DEV_IP_DASHED>.sslip.io` |
| Port-forward | `http://localhost:8000` |
| Tilt dashboard | `http://localhost:10350` |

Edit `app/src/demo_app/**` → synced into the pod, uvicorn reloads in ~1s (no rebuild).  
Edit `pyproject.toml` / `uv.lock` → triggers in-pod `uv sync`.  
Edit `Dockerfile.dev` → triggers a full image rebuild.

### Stopping

```bash
tilt down
```

`tilt down` removes the `demo-dev` Helm release. The `demo-db` CNPG cluster and the
`traefik-dev` LoadBalancer remain. To remove everything:

```bash
./scripts/teardown.sh
```

### Data isolation

The dev deployment writes to a `dev` schema inside the shared `demo` database.
`migrations/env.py` creates the schema on startup (`CREATE SCHEMA IF NOT EXISTS dev`)
and sets `search_path` so all tables land there, leaving the `public` schema
(used by the prod `demo` namespace) untouched.

### Schema

```
demo-db (CNPG cluster, namespace demo-db)
├── public schema  ← prod app (demo namespace, optional --with-app)
└── dev schema     ← dev app  (demo-dev namespace, tilt up)
```
