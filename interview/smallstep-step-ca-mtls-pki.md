---
sessionID: ses_18fa35214ffe7Wxb099GkmRCBK
baseMessageCount: 43
updatedAt: 2026-05-29T06:52:32.067Z
---

# I want to expand the (m)TLS and PKI part of this setup by adding an offline root and intermediate CA, managed by "SmallStep step-ca"

## Current spec

step-ca provides an offline root CA and intermediate CA. Vault PKI becomes a subordinate CA, chaining to step-ca's intermediate as its root. The hierarchy: Offline Root (step-ca) → Intermediate CA (step-ca) → Vault PKI (subordinate) → leaf certs. Primary consumers are PostgreSQL mTLS and Kubernetes workload mTLS (SPIFFE-style).

## Q&A history

Q: Should step-ca replace the existing Vault PKI + cert-manager pipeline, or coexist alongside it?
A: step-ca provides root CA and intermediate CA. Vault PKI uses the intermediate CA as its own root CA and builds from there.

Q: What should step-ca primarily issue certificates for?
A: PostgreSQL mTLS + Kubernetes workload mTLS (service mesh / SPIFFE-style)
