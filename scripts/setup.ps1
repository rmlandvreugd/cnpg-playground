# MinIO settings and credentials
$MINIO_IMAGE ??="quay.io/minio/minio:RELEASE.2024-09-13T20-26-02Z"
$MINIO_EU_ROOT_USER ??="cnpg-eu"
$MINIO_EU_ROOT_PASSWORD ??="postgres5432-eu"
$MINIO_US_ROOT_USER ??="cnpg-us"
$MINIO_US_ROOT_PASSWORD ??="postgres5432-us"

# Ensure prerequisites are met
# $prereqs = "kind kubectl git"
# $executables = $prereqs.Split(" ")

$prereqs = "kind","kubectl","git"
foreach ($cmd in $prereqs) {
    try {
        if (-not (Get-Command $cmd -ErrorAction Stop)) {
            throw "Missing command: $cmd"
        }
    }
    catch {
        Write-Output $_.Exception.Message
        exit 1
    }
}

# Define the supported container providers
$containerProviders = "docker", "podman"

# Look for a supported container provider and use it throughout
$CONTAINER_PROVIDER = $null
foreach ($provider in $containerProviders) {
    if (Get-Command $provider -ErrorAction SilentlyContinue) {
        $CONTAINER_PROVIDER = $provider
        break
    }
}

# Ensure we found a supported container provider
if (-not $CONTAINER_PROVIDER) {
    Write-Output "Missing container provider, supported providers are $($containerProviders -join ', ')"
    exit 1
}

$gitRepoRoot = & git rev-parse --show-toplevel
$kubeConfigPath = "$gitRepoRoot/k8s/kube-config.yaml"
$kindConfigPath = "$gitRepoRoot/k8s/kind-cluster.yaml"

# Setup a separate Kubeconfig
Set-Location -Path $gitRepoRoot
$env:KUBECONFIG = $kubeConfigPath

# Setup the object stores
New-Item -ItemType Directory -Path "minio-eu" -Force
& $CONTAINER_PROVIDER run --name minio-eu -d -v "$gitRepoRoot/minio-eu:/data" -e "MINIO_ROOT_USER=$MINIO_EU_ROOT_USER" -e "MINIO_ROOT_PASSWORD=$MINIO_EU_ROOT_PASSWORD" -u 1000:1000 $MINIO_IMAGE server /data --console-address ":9001"

New-Item -ItemType Directory -Path "minio-us" -Force
& $CONTAINER_PROVIDER run --name minio-us -d -v "$gitRepoRoot/minio-us:/data" -e "MINIO_ROOT_USER=$MINIO_US_ROOT_USER" -e "MINIO_ROOT_PASSWORD=$MINIO_US_ROOT_PASSWORD" -u 1000:1000 $MINIO_IMAGE server /data --console-address ":9001"

# Setup the EU Kind Cluster
& kind create cluster --config $kindConfigPath --name k8s-eu
# The `node-role.kubernetes.io` label must be set after the node have been created
& kubectl label node -l postgres.node.kubernetes.io node-role.kubernetes.io/postgres=
& kubectl label node -l infra.node.kubernetes.io node-role.kubernetes.io/infra=
& kubectl label node -l app.node.kubernetes.io node-role.kubernetes.io/app=

# Setup the US Kind Cluster
& kind create cluster --config $kindConfigPath --name k8s-us
# The `node-role.kubernetes.io` label must be set after the node have been created
& kubectl label node -l postgres.node.kubernetes.io node-role.kubernetes.io/postgres=
& kubectl label node -l infra.node.kubernetes.io node-role.kubernetes.io/infra=
& kubectl label node -l app.node.kubernetes.io node-role.kubernetes.io/app=

& $CONTAINER_PROVIDER network connect kind minio-eu
& $CONTAINER_PROVIDER network connect kind minio-us

# Create the secrets for MinIO
$contexts = "kind-k8s-eu", "kind-k8s-us"
foreach ($context in $contexts) {
    & kubectl create secret generic minio-eu --context $context --from-literal=ACCESS_KEY_ID=$MINIO_EU_ROOT_USER --from-literal=ACCESS_SECRET_KEY=$MINIO_EU_ROOT_PASSWORD
    & kubectl create secret generic minio-us --context $context --from-literal=ACCESS_KEY_ID=$MINIO_US_ROOT_USER --from-literal=ACCESS_SECRET_KEY=$MINIO_US_ROOT_PASSWORD
}

& ./scripts/info.ps1