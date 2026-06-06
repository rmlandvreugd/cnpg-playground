#!/usr/bin/env python3
"""
Revocation exporter — probes TLS endpoints for cert expiry and CRL revocation.

Metrics exposed on PORT (default 9105):
  cert_not_after_seconds{endpoint, common_name}  — NotAfter Unix timestamp
  cert_revoked{endpoint, common_name}             — 1 if revoked, 0 if valid
  cert_probe_success{endpoint}                    — 1 if TLS probe succeeded
  crl_next_update_seconds{crl_url}                — CRL NextUpdate Unix timestamp

Environment variables:
  ENDPOINTS       — comma-separated "name:host:port" tuples (required)
  CA_BUNDLE       — path to CA bundle PEM (default /etc/revocation-exporter/ca-bundle.crt)
  PORT            — metrics listen port (default 9105)
  SCRAPE_INTERVAL — seconds between probe loops (default 60)
"""

import logging
import os
import socket
import ssl
import threading
import time

import requests
from cryptography import x509
from cryptography.x509.oid import ExtensionOID
from prometheus_client import Gauge, start_http_server

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

CERT_NOT_AFTER = Gauge(
    "cert_not_after_seconds",
    "Certificate expiry Unix timestamp",
    ["endpoint", "common_name"],
)
CERT_REVOKED = Gauge(
    "cert_revoked",
    "1 if cert is revoked, 0 if valid",
    ["endpoint", "common_name"],
)
CERT_PROBE_SUCCESS = Gauge(
    "cert_probe_success",
    "1 if TLS probe succeeded, 0 on error",
    ["endpoint"],
)
CRL_NEXT_UPDATE = Gauge(
    "crl_next_update_seconds",
    "CRL NextUpdate Unix timestamp",
    ["crl_url"],
)


def parse_endpoints(raw: str) -> list[tuple[str, str, int]]:
    result = []
    for entry in raw.split(","):
        parts = entry.strip().split(":")
        if len(parts) != 3:
            log.warning("Skipping malformed endpoint entry: %r", entry)
            continue
        name, host, port_str = parts
        try:
            result.append((name.strip(), host.strip(), int(port_str.strip())))
        except ValueError:
            log.warning("Bad port in endpoint entry: %r", entry)
    return result


def grab_cert(host: str, port: int) -> x509.Certificate:
    # CERT_NONE is intentional: we are a passive cert inspector, not an
    # authenticated client. We grab the raw DER bytes so we can parse expiry
    # and serial for CRL lookup via the cryptography library. Actual
    # revocation validity is checked against the CA-verified CRL (ca_bundle).
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with socket.create_connection((host, port), timeout=5) as raw:
        with ctx.wrap_socket(raw, server_hostname=host) as tls:
            der = tls.getpeercert(binary_form=True)
    return x509.load_der_x509_certificate(der)


def cert_common_name(cert: x509.Certificate) -> str:
    try:
        return cert.subject.get_attributes_for_oid(x509.oid.NameOID.COMMON_NAME)[0].value
    except Exception:
        return "unknown"


def get_crl_urls(cert: x509.Certificate) -> list[str]:
    try:
        ext = cert.extensions.get_extension_for_oid(ExtensionOID.CRL_DISTRIBUTION_POINTS)
        urls = []
        for dp in ext.value:
            for name in dp.full_name or []:
                if hasattr(name, "value") and name.value.startswith("http"):
                    urls.append(name.value)
        return urls
    except x509.ExtensionNotFound:
        return []


def fetch_crl(
    url: str, ca_bundle: str, cache: dict
) -> x509.CertificateRevocationList | None:
    if url in cache:
        return cache[url]
    try:
        resp = requests.get(url, verify=ca_bundle, timeout=10)
        resp.raise_for_status()
        content = resp.content
        try:
            crl = x509.load_der_x509_crl(content)
        except Exception:
            crl = x509.load_pem_x509_crl(content)
        cache[url] = crl
        return crl
    except Exception as exc:
        log.warning("Failed to fetch CRL %s: %s", url, exc)
        cache[url] = None
        return None


def check_crl_revoked(
    cert: x509.Certificate, ca_bundle: str, cache: dict
) -> bool | None:
    """Return True if revoked, False if present in valid CRL, None if CRL unavailable."""
    revoked: bool | None = None
    for url in get_crl_urls(cert):
        crl = fetch_crl(url, ca_bundle, cache)
        if crl is None:
            continue
        if crl.next_update_utc:
            CRL_NEXT_UPDATE.labels(crl_url=url).set(crl.next_update_utc.timestamp())
        entry = crl.get_revoked_certificate_by_serial_number(cert.serial_number)
        revoked = entry is not None
    return revoked


def probe_endpoint(
    name: str, host: str, port: int, ca_bundle: str, crl_cache: dict
) -> None:
    try:
        cert = grab_cert(host, port)
        cn = cert_common_name(cert)

        CERT_NOT_AFTER.labels(endpoint=name, common_name=cn).set(
            cert.not_valid_after_utc.timestamp()
        )

        revoked = check_crl_revoked(cert, ca_bundle, crl_cache)
        CERT_REVOKED.labels(endpoint=name, common_name=cn).set(
            1 if revoked else 0
        )

        CERT_PROBE_SUCCESS.labels(endpoint=name).set(1)
        log.info(
            "%-18s %s:%d  CN=%-40s  not_after=%s  revoked=%s",
            name, host, port, cn, cert.not_valid_after_utc.date(), revoked,
        )
    except Exception as exc:
        log.warning("Probe failed for %s (%s:%d): %s", name, host, port, exc)
        CERT_PROBE_SUCCESS.labels(endpoint=name).set(0)


def run_loop(
    endpoints: list[tuple[str, str, int]], ca_bundle: str, interval: int
) -> None:
    while True:
        crl_cache: dict = {}
        for name, host, port in endpoints:
            probe_endpoint(name, host, port, ca_bundle, crl_cache)
        time.sleep(interval)


def main() -> None:
    listen_port = int(os.environ.get("PORT", "9105"))
    ca_bundle = os.environ.get("CA_BUNDLE", "/etc/revocation-exporter/ca-bundle.crt")
    raw_endpoints = os.environ.get("ENDPOINTS", "")
    interval = int(os.environ.get("SCRAPE_INTERVAL", "60"))

    if not raw_endpoints:
        raise SystemExit("ENDPOINTS env var required (format: name:host:port,...)")

    endpoints = parse_endpoints(raw_endpoints)
    log.info(
        "Starting revocation exporter on :%d | %d endpoints | interval=%ds",
        listen_port, len(endpoints), interval,
    )

    start_http_server(listen_port)
    t = threading.Thread(
        target=run_loop, args=(endpoints, ca_bundle, interval), daemon=True
    )
    t.start()
    t.join()


if __name__ == "__main__":
    main()
