#!/bin/sh
# Replace Docker's embedded DNS (127.0.0.11) with every nameserver Podman put
# in resolv.conf. aardvark-dns is not 127.0.0.11, and nginx proxy_pass via a
# variable (api, frontend) fails every request until this rewrite runs.
# The compose entrypoint invokes this with `sh`, from /opt/maku/, because a
# Windows bind is not reliably executable and /docker-entrypoint.d skips those.
#
# RESOLV_CONF, NGINX_UPSTREAM, and NGINX_CONF override the container paths
# for a local diff test. The container uses the defaults.

set -eu

resolv=${RESOLV_CONF:-/etc/resolv.conf}
upstream=${NGINX_UPSTREAM:-/etc/nginx/nginx.conf.upstream}
target=${NGINX_CONF:-/etc/nginx/nginx.conf}

if [ ! -f "$upstream" ]; then
    echo "05-podman-resolver: $upstream is not mounted" >&2
    exit 1
fi
if [ ! -f "$resolv" ]; then
    echo "05-podman-resolver: $resolv is missing" >&2
    exit 1
fi

# Every nameserver, space-separated. nginx accepts an IPv6 address only in brackets.
ns=$(awk '
/^[[:space:]]*nameserver[[:space:]]+/ {
    addr = $2
    if (addr == "") next
    if (addr ~ /:/ && addr !~ /^\[/) {
        addr = "[" addr "]"
    }
    if (out == "") out = addr
    else out = out " " addr
}
END { print out }
' "$resolv")

if [ -z "${ns:-}" ]; then
    echo "05-podman-resolver: no nameserver in $resolv" >&2
    exit 1
fi

# index/substr, not gsub: the address is inserted as text. "&" and "\" would
# be replacement metacharacters under gsub, and an IPv6 address contains ":".
awk -v ns="$ns" '
{
    needle = "resolver 127.0.0.11"
    i = index($0, needle)
    if (i > 0) {
        $0 = substr($0, 1, i - 1) "resolver " ns substr($0, i + length(needle))
    }
    print
}
' "$upstream" > "$target"

if ! grep -F "resolver ${ns}" "$target" >/dev/null; then
    echo "05-podman-resolver: resolver was not rewritten" >&2
    exit 1
fi
if grep -q "resolver 127\\.0\\.0\\.11" "$target"; then
    echo "05-podman-resolver: Docker resolver 127.0.0.11 is still present" >&2
    exit 1
fi

echo "05-podman-resolver: resolver set to ${ns}"
