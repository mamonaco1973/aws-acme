#!/bin/bash
# ==============================================================================
# userdata.sh.tpl — build the NGINX + Apache server and get its certificate
#
# Order matters:
#   1. Apache serves the demo page on 127.0.0.1:8080 only.
#   2. certbot gets the certificate from the ACM ACME endpoint.
#   3. NGINX starts listening on 443 with that certificate and proxies to
#      Apache.
#
# Progress goes to /var/log/acme-lab-bootstrap.log. The last step writes
# /var/lib/acme-lab/ready, which apply.sh waits for.
# ==============================================================================

set -euxo pipefail
exec > >(tee -a /var/log/acme-lab-bootstrap.log) 2>&1

FQDN="${fqdn}"
ACME_SERVER="${acme_directory_url}"
EAB_ARN="${eab_arn}"
CERT_NAME="acme-lab"
LIVE_DIR="/etc/letsencrypt/live/$${CERT_NAME}"

# ------------------------------------------------------------------------------
# Packages
# ------------------------------------------------------------------------------
# Ubuntu's certbot (2.9) already has the EAB options and --issuance-timeout,
# and ships certbot.timer for renewals. Nothing comes from snap: the snap
# store is unreliable this early in boot. The AWS CLI v2 comes from AWS's
# own installer.
# ------------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apache2 nginx certbot jq unzip

curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

# NGINX's stock site listens on port 80. Nothing should, so drop it and keep
# NGINX stopped until it has a certificate to serve.
rm -f /etc/nginx/sites-enabled/default
systemctl stop nginx

# ------------------------------------------------------------------------------
# Apache: loopback only, port 8080
# ------------------------------------------------------------------------------
# Server Side Includes let the page show what Apache actually received from
# NGINX (client address, forwarded headers) and include the certificate
# summary that the certbot deploy hook writes.
# ------------------------------------------------------------------------------

cat > /etc/apache2/ports.conf <<'EOF'
Listen 127.0.0.1:8080
EOF

cat > /etc/apache2/sites-available/000-default.conf <<'EOF'
<VirtualHost 127.0.0.1:8080>
    DocumentRoot /var/www/html
    <Directory /var/www/html>
        Options +Includes
        AddOutputFilter INCLUDES .html
    </Directory>
    ErrorLog $${APACHE_LOG_DIR}/error.log
    CustomLog $${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

a2enmod include

cat > /var/www/html/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ACM ACME Lab</title>
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
  <h1>Served by Apache through NGINX</h1>
  <p class="sub">NGINX ended TLS with a certificate from the AWS Certificate Manager ACME endpoint
  and passed the request to Apache on 127.0.0.1:8080.</p>

  <h2>What Apache received</h2>
  <table>
    <tr><th>Apache saw the client as</th><td><!--#echo var="REMOTE_ADDR" --></td></tr>
    <tr><th>Real client (X-Real-IP)</th><td><!--#echo var="HTTP_X_REAL_IP" --></td></tr>
    <tr><th>X-Forwarded-Proto</th><td><!--#echo var="HTTP_X_FORWARDED_PROTO" --></td></tr>
    <tr><th>TLS protocol at NGINX</th><td><!--#echo var="HTTP_X_TLS_PROTOCOL" --></td></tr>
    <tr><th>TLS cipher at NGINX</th><td><!--#echo var="HTTP_X_TLS_CIPHER" --></td></tr>
    <tr><th>Rendered</th><td><!--#echo var="DATE_GMT" --></td></tr>
  </table>

  <h2>Certificate NGINX is serving</h2>
  <!--#include virtual="/cert.html" -->
</body>
</html>
EOF

systemctl restart apache2

# ------------------------------------------------------------------------------
# certbot deploy hook
# ------------------------------------------------------------------------------
# Runs after every successful issuance or renewal: rewrites the certificate
# summary that the page includes, then checks and reloads NGINX so the new
# certificate is live without a restart.
# ------------------------------------------------------------------------------

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/bash
set -euo pipefail

cert="/etc/letsencrypt/live/acme-lab/cert.pem"

field() { openssl x509 -in "$cert" -noout "$@" | cut -d= -f2-; }

cat > /var/www/html/cert.html <<HTML
<table>
  <tr><th>Names (SAN)</th><td>$(openssl x509 -in "$cert" -noout -ext subjectAltName | tail -n 1 | tr -d ' ')</td></tr>
  <tr><th>Issuer</th><td>$(field -issuer)</td></tr>
  <tr><th>Serial</th><td>$(field -serial)</td></tr>
  <tr><th>Not before</th><td>$(field -startdate)</td></tr>
  <tr><th>Not after</th><td>$(field -enddate)</td></tr>
  <tr><th>Installed</th><td>$(date -u)</td></tr>
</table>
HTML

nginx -t
systemctl reload nginx
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ------------------------------------------------------------------------------
# Certificate from the ACM ACME endpoint
# ------------------------------------------------------------------------------
# The EAB key ID and MAC key are read from ACM with the instance role and
# used once, to register certbot's ACME account. The endpoint approved the
# domain in advance, so certbot gets no challenge and standalone mode never
# opens a port. ACM can take up to two minutes to issue, hence the timeout.
# ------------------------------------------------------------------------------

eab=$(aws acm get-acme-external-account-binding-credentials \
  --region us-east-1 \
  --acme-external-account-binding-arn "$${EAB_ARN}" \
  --output json)

certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  --server "$${ACME_SERVER}" \
  --eab-kid "$(jq -r .KeyId <<<"$${eab}")" \
  --eab-hmac-key "$(jq -r .MacKey <<<"$${eab}")" \
  --issuance-timeout 120 \
  --key-type ecdsa \
  --cert-name "$${CERT_NAME}" \
  --domain "$${FQDN}"

unset eab

# ------------------------------------------------------------------------------
# NGINX: TLS on 443, proxy to Apache
# ------------------------------------------------------------------------------

cat > /etc/nginx/sites-available/acme-lab <<EOF
server {
    listen 443 ssl http2;
    server_name $${FQDN};

    ssl_certificate     $${LIVE_DIR}/fullchain.pem;
    ssl_certificate_key $${LIVE_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   X-TLS-Protocol    \$ssl_protocol;
        proxy_set_header   X-TLS-Cipher      \$ssl_cipher;
    }
}
EOF
ln -sf /etc/nginx/sites-available/acme-lab /etc/nginx/sites-enabled/acme-lab

systemctl start nginx
systemctl enable nginx

# First run of the hook: writes cert.html and reloads NGINX.
/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

mkdir -p /var/lib/acme-lab
touch /var/lib/acme-lab/ready
