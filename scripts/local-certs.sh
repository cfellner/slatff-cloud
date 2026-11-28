#!/usr/bin/env bash
# Local mode (docs/LOCAL.md): makes a private certificate authority and one certificate for
# id/ai/meet/files.slatff.test in ./local. The CA key is deleted straight after signing, so
# nothing else can ever be issued from this CA. Run again to replace both (then trust the new CA).
# Usage: ./scripts/local-certs.sh
set -euo pipefail
cd "$(dirname "$0")/.."

domain=slatff.test
out=local
days=825   # Apple accepts at most 825 days for certificates from a private CA

mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/ca.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = SLATFF.Cloud local mode CA ($domain only)
[v3_ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
nameConstraints = critical,permitted;DNS:$domain
subjectKeyIdentifier = hash
CNF

cat > "$tmp/leaf.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $domain local mode
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:id.$domain,DNS:ai.$domain,DNS:meet.$domain,DNS:files.$domain
CNF

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$days" \
  -config "$tmp/ca.cnf" -keyout "$tmp/ca.key" -out "$out/ca.crt" 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -config "$tmp/leaf.cnf" \
  -keyout "$out/tls.key" -out "$tmp/tls.csr" 2>/dev/null
openssl x509 -req -sha256 -days "$days" -in "$tmp/tls.csr" \
  -CA "$out/ca.crt" -CAkey "$tmp/ca.key" -CAserial "$tmp/ca.srl" -CAcreateserial \
  -extfile "$tmp/leaf.cnf" -extensions ext -out "$out/tls.crt" 2>/dev/null
chmod 644 "$out/ca.crt" "$out/tls.crt"
chmod 600 "$out/tls.key"
openssl verify -CAfile "$out/ca.crt" "$out/tls.crt" >/dev/null

echo "Wrote $out/ca.crt, $out/tls.crt and $out/tls.key for *.$domain ($days days). CA key deleted."
