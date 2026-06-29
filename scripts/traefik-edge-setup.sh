#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TRAEFIK_EDGE_DIR="${GIT_REPO_ROOT}/traefik-edge"
TRAEFIK_EDGE_CERTS_DIR="${TRAEFIK_EDGE_DIR}/certs"
STEP_CA_PKI_DIR="${GIT_REPO_ROOT}/step-ca/pki"
STEP_CA_SECRETS_DIR="${GIT_REPO_ROOT}/step-ca/secrets"

HOST_IP=$(hostname -I | awk '{print $1}')
HOST_IP_DASHED=$(echo "$HOST_IP" | tr '.' '-')
STEP_CA_HOST="step-ca.${HOST_IP_DASHED}.sslip.io"

echo "🔒 Provisioning TLS certificates for external edge Traefik..."

sudo mkdir -p "${TRAEFIK_EDGE_CERTS_DIR}"

# step-ca chain for OTLP mTLS CA verification (referenced in traefik.yaml)
sudo bash -c "cat '${STEP_CA_PKI_DIR}/intermediate_ca.crt' '${STEP_CA_PKI_DIR}/root_ca.crt' \
    > '${TRAEFIK_EDGE_CERTS_DIR}/step-ca-chain.pem'"
sudo chmod 644 "${TRAEFIK_EDGE_CERTS_DIR}/step-ca-chain.pem"

# Stage intermediate CA materials in step-ca container for X5C provisioner
${CONTAINER_PROVIDER} cp "${STEP_CA_PKI_DIR}/intermediate_ca.crt"    "${STEP_CA_CONTAINER_NAME}:/tmp/edge_intermediate_ca.crt"
${CONTAINER_PROVIDER} cp "${STEP_CA_SECRETS_DIR}/intermediate_ca_key" "${STEP_CA_CONTAINER_NAME}:/tmp/edge_intermediate_ca_key"

_issue_cert() {
    local name="$1"       # output file stem (vault, authelia, seaweedfs, seaweedfs-admin)
    local primary="$2"    # primary SAN / CN
    shift 2
    local extra_sans=("$@")

    echo "📜 Issuing TLS cert: ${primary}..."

    local san_args=("--san" "${primary}")
    for s in "${extra_sans[@]}"; do
        san_args+=("--san" "$s")
    done

    local tmp_cert="/tmp/edge-${name}-cert.pem"
    local tmp_key="/tmp/edge-${name}-key.pem"

    ${CONTAINER_PROVIDER} exec \
        -e STEPPATH=/home/step \
        "${STEP_CA_CONTAINER_NAME}" \
        step ca certificate "${primary}" "${tmp_cert}" "${tmp_key}" \
        --provisioner x5c-provisioner \
        --x5c-cert /tmp/edge_intermediate_ca.crt \
        --x5c-key  /tmp/edge_intermediate_ca_key \
        --x5c-chain /tmp/edge_intermediate_ca.crt \
        --password-file /home/step/secrets/password \
        --ca-url "https://${STEP_CA_HOST}:${STEP_CA_PORT}" \
        --root /home/step/certs/root_ca.crt \
        "${san_args[@]}" \
        --not-after 720h --force

    local tmp_dir
    tmp_dir=$(mktemp -d)
    ${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:${tmp_cert}" "${tmp_dir}/cert.pem"
    ${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:${tmp_key}"  "${tmp_dir}/key.pem"

    # Full chain: leaf + intermediate + root (mirrors authelia-setup.sh pattern)
    sudo bash -c "cat '${tmp_dir}/cert.pem' \
        '${STEP_CA_PKI_DIR}/intermediate_ca.crt' \
        '${STEP_CA_PKI_DIR}/root_ca.crt' \
        > '${TRAEFIK_EDGE_CERTS_DIR}/${name}.crt'"
    sudo cp "${tmp_dir}/key.pem" "${TRAEFIK_EDGE_CERTS_DIR}/${name}.key"
    sudo chmod 644 "${TRAEFIK_EDGE_CERTS_DIR}/${name}.crt"
    sudo chmod 640 "${TRAEFIK_EDGE_CERTS_DIR}/${name}.key"
    rm -rf "${tmp_dir}"

    ${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" rm -f "${tmp_cert}" "${tmp_key}"
}

_issue_cert "vault" \
    "vault.${TRAEFIK_EDGE_IP_DASHED}.sslip.io" \
    "vault" "localhost" "127.0.0.1"

_issue_cert "authelia" \
    "authelia.${TRAEFIK_EDGE_IP_DASHED}.sslip.io" \
    "authelia" "localhost" "127.0.0.1"

_issue_cert "seaweedfs" \
    "seaweedfs.${TRAEFIK_EDGE_IP_DASHED}.sslip.io" \
    "seaweedfs" "localhost" "127.0.0.1"

_issue_cert "seaweedfs-admin" \
    "seaweedfs-admin.${TRAEFIK_EDGE_IP_DASHED}.sslip.io" \
    "seaweedfs-admin" "localhost" "127.0.0.1"

# Clean up intermediate CA materials from step-ca container
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" rm -f \
    /tmp/edge_intermediate_ca.crt /tmp/edge_intermediate_ca_key

echo "✅ Edge TLS certs provisioned in ${TRAEFIK_EDGE_CERTS_DIR}/"
echo "   ⚠️  OTLP mTLS client cert (otlp-client.crt/key) provisioned in cnpg-playground-5sq.6"
