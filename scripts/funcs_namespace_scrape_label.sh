#!/usr/bin/env bash

# Label a namespace for scrape inclusion. Idempotent.
label_namespace_for_scrape() {
    local context="$1"
    local namespace="$2"
    kubectl --context "${context}" label namespace "${namespace}" \
        monitoring/scrape=enabled --overwrite
}

# Get comma-separated list of labeled namespaces (for SCRAPE_NAMESPACES_RIVER derivation).
get_scrape_namespaces() {
    local context="$1"
    kubectl --context "${context}" get namespaces \
        -l monitoring/scrape=enabled \
        -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}' | sed 's/,$//'
}
