#!/bin/bash
# ==============================================================================
# backend.sh.tpl — build one load balancer backend
#
# The same script builds all three backends; CERT_MODE picks the kind:
#
#   A  plain            none      NGINX on port 80, plain HTTP       (option a)
#   B  self-signed      expired   NGINX on port 443, broken cert     (option b)
#   C  self-signed-10y  valid10y  NGINX on port 443, ten-year cert   (option b)
#
# (B follows backend_cert_mode, so it can be flipped to valid10y too.)
#
# All serve one diagnostic page at any path, so the ALB's path prefixes and
# the NLB's bare / all land on it. NGINX fills the page in per
# request with sub_filter: no Apache, no application server.
#
# Progress goes to /var/log/acme-lab-bootstrap.log. The last step writes
# /var/lib/acme-lab/ready, which apply.sh waits for.
# ==============================================================================

set -euxo pipefail
exec > >(tee -a /var/log/acme-lab-bootstrap.log) 2>&1

BACKEND="${backend}"
LABEL="${label}"
CERT_MODE="${cert_mode}"
CERT_DIR="/etc/nginx/backend-cert"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx openssl

rm -f /etc/nginx/sites-enabled/default

# ------------------------------------------------------------------------------
# Self-signed certificate (backends B and C)
# ------------------------------------------------------------------------------
# expired:  valid 2024-01-01 to 2025-01-01, named nobody-checks-this.invalid.
#           Wrong on every count a client would check, on purpose: the load
#           balancers use it anyway.
# valid10y: ten years from yesterday, named tls-backend.internal.
#
# "openssl req -x509" cannot set a start date in the past on OpenSSL 3.0
# (Ubuntu 24.04), so the certificate is signed by "openssl ca -selfsign",
# which takes explicit -startdate and -enddate.
# ------------------------------------------------------------------------------

if [[ "$${CERT_MODE}" != "none" ]]; then
  case "$${CERT_MODE}" in
    expired)
      CN="nobody-checks-this.invalid"
      START="20240101000000Z"
      END="20250101000000Z"
      ;;
    valid10y)
      CN="tls-backend.internal"
      START="$(date -u -d 'yesterday' +%Y%m%d%H%M%SZ)"
      END="$(date -u -d '+10 years' +%Y%m%d%H%M%SZ)"
      ;;
    *)
      echo "Unknown cert mode $${CERT_MODE}"
      exit 1
      ;;
  esac

  mkdir -p "$${CERT_DIR}/ca/newcerts"
  touch "$${CERT_DIR}/ca/index.txt"
  echo 1000 > "$${CERT_DIR}/ca/serial"

  cat > "$${CERT_DIR}/ca/ca.cnf" <<EOF
[ ca ]
default_ca = backend

[ backend ]
dir             = $${CERT_DIR}/ca
database        = \$dir/index.txt
new_certs_dir   = \$dir/newcerts
serial          = \$dir/serial
default_md      = sha256
policy          = any
unique_subject  = no
x509_extensions = server

[ any ]
commonName = supplied

[ server ]
basicConstraints = critical,CA:FALSE
keyUsage         = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = DNS:$${CN}
EOF

  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$${CERT_DIR}/backend.key" \
    -subj "/CN=$${CN}" \
    -out "$${CERT_DIR}/backend.csr"

  openssl ca -batch -notext -selfsign \
    -config "$${CERT_DIR}/ca/ca.cnf" \
    -keyfile "$${CERT_DIR}/backend.key" \
    -in "$${CERT_DIR}/backend.csr" \
    -out "$${CERT_DIR}/backend.crt" \
    -startdate "$${START}" -enddate "$${END}"

  chmod 600 "$${CERT_DIR}/backend.key"

  crt="$${CERT_DIR}/backend.crt"
  field() { openssl x509 -in "$crt" -noout "$@" | cut -d= -f2-; }

  if openssl x509 -in "$crt" -noout -checkend 0 > /dev/null; then
    status="valid"
  else
    status="EXPIRED"
  fi

  TITLE="Served by backend $${LABEL} (self-signed TLS)"
  SUMMARY="The load balancer ended the client's TLS with its ACM certificate, then opened a new TLS connection to this NGINX on port 443."
  CERT_TABLE="<table>
    <tr><th>Subject</th><td id=\"cert_subject\">$(field -subject)</td></tr>
    <tr><th>Names (SAN)</th><td id=\"cert_san\">$(openssl x509 -in "$crt" -noout -ext subjectAltName | tail -n 1 | tr -d ' ')</td></tr>
    <tr><th>Issuer</th><td id=\"cert_issuer\">$(field -issuer) (self-signed)</td></tr>
    <tr><th>Not before</th><td id=\"cert_not_before\">$(field -startdate)</td></tr>
    <tr><th>Not after</th><td id=\"cert_not_after\">$(field -enddate)</td></tr>
    <tr><th>Status</th><td id=\"cert_status\">$${status}</td></tr>
    <tr><th>backend_cert_mode</th><td id=\"cert_mode\">$${CERT_MODE}</td></tr>
  </table>"

  cat > /etc/nginx/lab-listen.conf <<EOF
listen 443 ssl default_server;
ssl_certificate     $${CERT_DIR}/backend.crt;
ssl_certificate_key $${CERT_DIR}/backend.key;
ssl_protocols       TLSv1.2 TLSv1.3;
EOF
else
  TITLE="Served by backend $${LABEL} (plain HTTP)"
  SUMMARY="The load balancer ended the client's TLS with its ACM certificate and sent the request on to this NGINX as plain HTTP on port 80."
  CERT_TABLE="<p class=\"sub\" id=\"cert_none\">None. This backend has no certificate and speaks plain HTTP.</p>"

  cat > /etc/nginx/lab-listen.conf <<'EOF'
listen 80 default_server;
EOF
fi

# ------------------------------------------------------------------------------
# Diagnostic page
# ------------------------------------------------------------------------------
# Static HTML with @NAME@ placeholders; the sub_filter lines in the server
# block below swap in what NGINX saw on each request. The id attributes let
# validate.sh read the values back.
# ------------------------------------------------------------------------------

mkdir -p /var/www/lab
cat > /var/www/lab/index.html <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ACM ACME Lab - backend $${BACKEND}</title>
  <style>
    /* Follows the browser's light or dark preference. */
    :root { color-scheme: light dark;
            --bg: #f7f9fb; --panel: #ffffff; --text: #1f2933;
            --muted: #52606d; --rule: #e4e7eb; }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #0d1117; --panel: #161b22; --text: #e6edf3;
              --muted: #9ba7b4; --rule: #30363d; }
    }
    body { font-family: system-ui, sans-serif; max-width: 46rem; margin: 3rem auto;
           padding: 0 1rem; color: var(--text); background: var(--bg); }
    h1 { margin-bottom: .25rem; }
    .sub { color: var(--muted); margin-top: 0; }
    table { border-collapse: collapse; width: 100%; margin: 1rem 0 2rem; background: var(--panel); }
    th, td { text-align: left; padding: .5rem .75rem; border-bottom: 1px solid var(--rule);
             vertical-align: top; }
    th { width: 14rem; color: var(--muted); font-weight: 600; }
    td { font-family: ui-monospace, monospace; word-break: break-all; }
  </style>
</head>
<body>
  <h1 id="backend" data-backend="$${BACKEND}">$${TITLE}</h1>
  <p class="sub">$${SUMMARY}</p>

  <h2>What NGINX received</h2>
  <table>
    <tr><th>Scheme received</th><td id="scheme">@SCHEME@</td></tr>
    <tr><th>TLS protocol</th><td id="tls_protocol">@TLS_PROTOCOL@</td></tr>
    <tr><th>TLS cipher</th><td id="tls_cipher">@TLS_CIPHER@</td></tr>
    <tr><th>Request path</th><td id="path">@PATH@</td></tr>
    <tr><th>Host header</th><td id="host">@HOST@</td></tr>
    <tr><th>Client address NGINX saw</th><td id="client">@CLIENT@</td></tr>
    <tr><th>X-Forwarded-For</th><td id="xff">@XFF@</td></tr>
    <tr><th>X-Forwarded-Proto</th><td id="xfp">@XFP@</td></tr>
    <tr><th>Rendered</th><td>@TIME@</td></tr>
  </table>

  <h2>Certificate this backend serves</h2>
  $${CERT_TABLE}
</body>
</html>
EOF

# ------------------------------------------------------------------------------
# NGINX
# ------------------------------------------------------------------------------
# The maps turn empty values into readable ones. Every path serves the same
# page, which also makes it the health check target.
# ------------------------------------------------------------------------------

cat > /etc/nginx/conf.d/lab-maps.conf <<'EOF'
map $ssl_protocol $lab_tls_protocol {
    ""      "none (plain HTTP)";
    default $ssl_protocol;
}

map $ssl_cipher $lab_tls_cipher {
    ""      "none";
    default $ssl_cipher;
}

map $http_x_forwarded_for $lab_xff {
    ""      "(not set)";
    default $http_x_forwarded_for;
}

map $http_x_forwarded_proto $lab_xfp {
    ""      "(not set)";
    default $http_x_forwarded_proto;
}
EOF

cat > /etc/nginx/sites-available/lab <<'EOF'
server {
    include /etc/nginx/lab-listen.conf;
    root    /var/www/lab;

    location / {
        default_type text/html;
        try_files    /index.html =404;
        add_header   Cache-Control "no-store" always;

        sub_filter_once off;
        sub_filter '@SCHEME@'       '$scheme';
        sub_filter '@TLS_PROTOCOL@' '$lab_tls_protocol';
        sub_filter '@TLS_CIPHER@'   '$lab_tls_cipher';
        sub_filter '@PATH@'         '$request_uri';
        sub_filter '@HOST@'         '$host';
        sub_filter '@CLIENT@'       '$remote_addr';
        sub_filter '@XFF@'          '$lab_xff';
        sub_filter '@XFP@'          '$lab_xfp';
        sub_filter '@TIME@'         '$time_iso8601';
    }
}
EOF
ln -sf /etc/nginx/sites-available/lab /etc/nginx/sites-enabled/lab

nginx -t
systemctl enable nginx
systemctl restart nginx

mkdir -p /var/lib/acme-lab
touch /var/lib/acme-lab/ready
