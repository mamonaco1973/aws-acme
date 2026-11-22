# The Certificate Apocalypse on AWS — ACM, ACME and Load Balancers

Public TLS certificates are about to stop being something you renew once a
year. The CA/Browser Forum's ballot SC-081 cuts the maximum lifetime of a
publicly trusted certificate in three steps, and cuts how long a CA may reuse
a domain validation along with it:

| From | Maximum certificate lifetime | Domain validation reuse |
|---|---|---|
| before March 2026 | 398 days | 398 days |
| 15 March 2026 | **200 days** | 200 days |
| 15 March 2027 | **100 days** | 100 days |
| 15 March 2029 | **47 days** | **10 days** |

At 47 days, every public certificate in an estate is renewed seven or eight
times a year. A calendar reminder, a ticket to the security team, a `.pfx`
pasted into a console: anything that involves a person turns into an outage
waiting to happen. The only certificates that survive are the ones **nobody
renews by hand**.

This project is a working lab for that problem on AWS. It sorts every
certificate in a typical EC2 web stack into one of three places, and builds
each one:

1. **On the load balancer, renewed by AWS.** A regular ACM certificate on an
   ALB or NLB. ACM renews it on its own however short lifetimes get, so it is
   already solved.
2. **Behind the load balancer, never renewed.** The hop from the load
   balancer to the instance. Neither the ALB nor the NLB checks the
   certificate a target presents, so it can be a **ten-year self-signed
   certificate** and drop out of the renewal problem entirely. The lab proves
   it with a backend whose certificate is expired, self-signed and names the
   wrong host, and both load balancers use it anyway.
3. **On the instance, renewed by ACME.** When a server has to present a
   public certificate itself, with no load balancer in front, the answer is an
   ACME client. **AWS Certificate Manager's ACME endpoint** lets certbot get
   publicly trusted Amazon certificates (already 45 days long) with no
   HTTP-01 or DNS-01 challenge, while the private key stays on the instance
   and ACM still lists every certificate in its inventory.

It uses **Terraform** (the `aws` and `awscc` providers) and a few shell
scripts to build, prove, renew and tear down the lab.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img alt="A browser reaches NGINX on an EC2 instance over HTTPS and NGINX proxies to Apache. certbot on the instance reads the EAB key once, sends ACME orders to the ACM ACME endpoint and reloads NGINX when a certificate lands. The endpoint approved the domain through a Route 53 validation CNAME and records each issued certificate in ACM. Below, in a second VPC, an ALB and an NLB end TLS with a regular ACM certificate and forward to a plain HTTP backend, to a backend whose self-signed certificate is expired and names the wrong host, and to a backend with a ten-year self-signed certificate; neither load balancer checks the backend certificate" src="architecture-light.svg">
</picture>

Regenerate the diagrams with `python make_diagram.py`.

## Where each certificate goes

There are three ways to run HTTPS for a site on EC2, and they differ in which
certificates exist and who renews them:

| Option | Client sees | Load balancer to instance | Certificate on the instance | Who renews | Shown by |
|---|---|---|---|---|---|
| **a** | ACM cert on the load balancer | plain HTTP | none | ACM | scenarios 2 and 3, backend A |
| **b** | ACM cert on the load balancer | TLS again | self-signed, ten years | ACM; nobody for the backend | scenarios 2 and 3, backend C |
| **c** | the instance's own cert | (no load balancer) | public, 45 days | certbot, against ACM's ACME endpoint | scenario 1, phases 1 and 2 |

* **Options a and b** keep the public certificate where AWS manages it. In
  November 2026 ACM already issues load balancer certificates for about 198
  days, under the 200-day limit, and it will keep shortening them without any
  change on your side. ACM certificates cannot leave AWS, so this only covers
  what sits behind ELB, CloudFront or API Gateway.
* **Option b** adds encryption on the last hop. Because no load balancer
  validates the target, the backend certificate is not part of the
  apocalypse: issue it once for ten years and forget it.
* **Option c** is the case lifetimes really hurt: a public certificate on a
  machine AWS does not manage. Something on the instance has to renew it every
  few weeks, reload the web server, and do it without anyone watching. That
  is an ACME client's whole job, and ACM's ACME endpoint lets it do that
  against Amazon's CA with AWS-side approval and inventory.

The lab builds all three side by side: **scenario 1** is option c, and
**scenarios 2 and 3** put options a and b behind an ALB and an NLB.

## Scenario 1: ACME on the instance (option c)

A small EC2 instance runs **certbot**, which requests its certificate from
ACM's ACME endpoint. **NGINX** serves it on port 443, and **Apache** produces
the page behind it on `127.0.0.1:8080`. The private key is generated on the
instance and **never leaves it**. ACM still records every certificate in its
inventory, with a stable ARN across renewals.

ACM's ACME support splits the job in two:

* **The administrator (phase 1, `01-acme/`)** creates an **ACME endpoint**,
  approves the domain once with a **domain validation**, and creates an
  **external account binding (EAB)** tied to an IAM role.
* **The server (phase 2, `02-server/`)** runs an ordinary ACME client
  (certbot) against the endpoint's directory URL, the same way it would talk to
  Let's Encrypt.

That split is what makes short lifetimes livable in a company: approving a
name is a one-time administrator decision made in AWS, while issuance and
every renewal after it are automatic on the server, with no challenge to
answer and no person in the loop.

The steps, in order:

1. **Endpoint.** `awscc_certificatemanager_acme_endpoint` creates a managed ACME
   server with `PRE_APPROVED` authorization and gives back a directory URL like
   `https://acm-acme-enroll.us-east-1.api.aws/<id>/directory`.
2. **Domain validation.** `awscc_certificatemanager_acme_domain_validation`
   approves exactly `acme-lab.mikes-cloud-solutions.com` (no apex, no other
   subdomains, no wildcards). Because the hosted zone ID is given, ACM writes
   the validation CNAME into Route 53 itself. It turns `VALID` in about a
   minute.
3. **Binding.** `awscc_certificatemanager_acme_external_account_binding`
   produces a key ID and MAC key. ACM assumes the binding's **issuer role**
   whenever certbot issues or revokes, and that role may only request
   certificates for the one demo name (`acm:DomainNames` condition).
4. **Server.** At boot the instance reads the EAB key ID and MAC key from ACM
   with its own instance role. They never appear in user data, Terraform state
   or outputs. certbot uses them **once** to register its ACME account.
5. **Issue.** certbot sends an order and a CSR. The domain is already
   approved, so there is **no HTTP-01 or DNS-01 challenge**: port 80 stays
   closed and certbot never touches DNS. ACM issues within about two minutes.
6. **Serve.** NGINX starts on 443 with the certificate and proxies to Apache.
   A certbot deploy hook reloads NGINX after every issuance and renewal.
7. **Renew.** Ubuntu's `certbot.timer` renews the certificate when it has 30
   days left, so a 45-day certificate is replaced about every two weeks.
   `renew.sh` forces one renewal to show it happening live.

### What the certificate looks like

| | |
|---|---|
| Issuer | Amazon (`Amazon ECDSA 256 S…`), Amazon Trust Services chain |
| Key | ECDSA P-256, generated by certbot on the instance |
| Validity | **45 days**, already shorter than the 2029 limit (renewed by certbot, not by ACM) |
| In ACM | Listed with `CertificateKeyPairOrigin = ACME` |
| ARN | Stays the same when the same ACME account renews the same names |

### Limits to know

* ACME certificates **cannot** be attached to ELB, CloudFront or API Gateway;
  AWS never holds the key. Use a normal ACM certificate for those (options a
  and b).
* `ExportCertificate`, `RenewCertificate` and `RevokeCertificate` do not apply.
  Revocation goes through the ACME endpoint (`certbot revoke`).
* ACM will not **delete** an ACME certificate before it expires. It removes it
  by itself one year after expiry.
* `hashicorp/aws` has no ACME resources yet, so phase 1 uses the `awscc`
  provider for the three ACME resources.

## Scenarios 2 and 3: behind a load balancer (options a and b)

Phase 3 (`03-lb/`) builds its own VPC with an **ALB** and an **NLB**. Both
end TLS with a regular DNS-validated ACM certificate and forward to three
private NGINX backends:

* **Backend A** speaks plain HTTP (option a).
* **Backend B** serves a self-signed certificate that is **expired and names
  the wrong host**. It exists to prove that nobody checks.
* **Backend C** serves a ten-year self-signed certificate (option b). This is
  the pattern to copy.

### The load balancers do not check the target's certificate

With option b, the load balancer opens a TLS connection to the instance and
encrypts the hop inside the VPC, but **it does not validate the certificate it
gets back**: not the issuer, not the name, not the dates. That is documented
for both the ALB and the NLB, and this lab proves it. Backend B's certificate:

* is self-signed, so no client trusts its issuer;
* is named `nobody-checks-this.invalid`, so it matches no lab host name;
* expired on 1 January 2025.

Both load balancers report the target healthy and serve its page. That is the
useful part for the 47-day era: the certificate behind a load balancer only
has to exist, so it can be a ten-year self-signed one and never needs
renewing. What it buys is encryption on the last hop, not proof of who is on
the other end; the security groups do that job.

**Backend C is the pattern to copy.** It serves the same kind of self-signed
certificate, but named `tls-backend.internal` and valid for ten years, so it
encrypts the hop without tripping scanners, auditors or anyone debugging with
`curl`, and nothing has to renew it for a decade. Backend B exists only to
prove the point.

The variable `backend_cert_mode` in `03-lb/main.tf` switches backend B
between the broken certificate and a sane one (backend C always has the
ten-year certificate):

| `backend_cert_mode` | Backend B certificate |
|---|---|
| `expired` (default) | `CN=nobody-checks-this.invalid`, valid 2024-01-01 to 2025-01-01 |
| `valid10y` | `CN=tls-backend.internal`, valid for ten years from the day before boot |

```bash
source lab.env      # sets TF_VAR_zone_name for Terraform
terraform -chdir=03-lb apply -var backend_cert_mode=valid10y
```

Changing it rebuilds backend B with the other certificate. (OpenSSL 3.0 on
Ubuntu 24.04 cannot backdate a certificate with `openssl req -x509`, so user
data signs it with `openssl ca -selfsign -startdate … -enddate …`.)

### Paths through the lab

| URL | Load balancer | Target group | Backend | Backend sees |
|---|---|---|---|---|
| `https://alb-lab.<zone>/http/` | ALB, HTTPS:443 | HTTP:80 | A, plain | `http`, ALB address, `X-Forwarded-For` set |
| `https://alb-lab.<zone>/tls/` | ALB, HTTPS:443 | HTTPS:443 | B, self-signed | `https`, ALB address, `X-Forwarded-For` set |
| `https://alb-lab.<zone>/tls10y/` | ALB, HTTPS:443 | HTTPS:443 | C, ten-year | `https`, ALB address, `X-Forwarded-For` set |
| `https://nlb-lab.<zone>/` | NLB, TLS:443 | TCP:80 | A, plain | `http`, **real client IP**, no `X-Forwarded-For` |
| `https://nlb-lab.<zone>:8443/` | NLB, TLS:8443 | TLS:443 | B, self-signed | `https`, **real client IP**, no `X-Forwarded-For` |
| `https://nlb-lab.<zone>:9443/` | NLB, TLS:9443 | TLS:443 | C, ten-year | `https`, **real client IP**, no `X-Forwarded-For` |

* The ALB routes by path prefix and answers anything else with a fixed 404. It
  speaks HTTP, so it adds `X-Forwarded-For` and `X-Forwarded-Proto`, and the
  backend sees the ALB's own private address as the client.
* The NLB passes bytes, not HTTP, so it adds no headers. Its targets are
  registered by instance ID, which keeps the client's own IP as the source
  address, so NGINX sees the real client directly.
* All three backends serve the same diagnostic page at any path: which
  backend answered, the scheme and TLS version it received, the request path,
  the client address NGINX saw, the forwarded headers, and (backends B and C)
  the certificate it serves. NGINX fills the page in per request with
  `sub_filter`; there is no Apache or application server in this phase. Like
  the phase 2 page, it follows the browser's light or dark setting.
* The backends sit in **private subnets with no public IP**. The load
  balancers are the only way in, and a NAT gateway is the only way out (apt
  and SSM). On top of that, their security group admits ports 80 and 443 only
  from the ALB's and the NLB's security groups. The NLB's security group is
  attached when it is created, which is the only time an NLB can get one.
* That is the contrast with scenario 1: `acme-web` has to be public, because
  browsers connect to it directly and it presents the public certificate
  itself. Behind a load balancer the instances never face a client, so they
  need neither a public address nor a public certificate. The lab runs one
  NAT gateway to keep the cost down; production would run one per
  Availability Zone.
* The load balancer certificate is a regular **DNS-validated ACM
  certificate** covering `alb-lab` and `nlb-lab`. It cannot be an ACME
  certificate from phase 1: AWS never holds an ACME certificate's private key,
  so those cannot be attached to ELB.

## Prerequisites

* [An AWS Account](https://aws.amazon.com/console/)
* A **public Route 53 hosted zone** for your domain, delegated from the
  registrar. This lab uses `mikes-cloud-solutions.com`; set `ZONE_NAME` in
  `lab.env` (the only place it lives) to use your own. The host labels
  (`acme-lab`, `alb-lab`, `nlb-lab`) are Terraform variables with defaults.
* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* [Terraform](https://developer.hashicorp.com/terraform/install)
* `jq`, `openssl`, `curl` and `dig` in PATH

`check_env.sh` checks all of these, and confirms that public DNS for the zone
points at the Route 53 name servers.

## Download

```bash
git clone https://github.com/mamonaco1973/aws-acme.git
cd aws-acme
```

## Deploy

```bash
./apply.sh
```

`apply.sh`:
1. `check_env.sh`: tools, AWS credentials, hosted zone and delegation.
2. `terraform apply` in `01-acme/`: endpoint, domain validation, issuer role
   and EAB. Waits until the domain validation is `VALID`.
3. `terraform apply` in `02-server/`: VPC, security group (443 only), EC2
   instance, Elastic IP and the `acme-lab` A record.
4. Waits, through SSM Run Command, for the instance to finish its user data:
   packages, certificate, NGINX.
5. `terraform apply` in `03-lb/`: a second VPC with public and private
   subnets and a NAT gateway, the ACM certificate and its DNS validation, the three backends, the ALB, the NLB
   and the `alb-lab` and `nlb-lab` alias records.
6. Waits, the same way, for all three backends to finish their user data, then for
   all six target groups to report their target healthy.
7. `validate.sh`.

Total time is about 11 minutes: phases 1 and 2 take about 4, phase 3 about 7.
The ALB and NLB take about two and a half minutes each to create (in
parallel), and the target groups another minute or two to see their targets
healthy. ACM validates the load balancer certificate within seconds of its
DNS records appearing.

## Validate

```bash
./validate.sh
```

```
============================================================================
ACM ACME Lab - Validation Output
============================================================================

NOTE: Site URL:          https://acme-lab.mikes-cloud-solutions.com
NOTE: Response:          Served by Apache through NGINX
NOTE: Issuer:            C=US, O=Amazon, CN=Amazon ECDSA 256 S13
NOTE: Serial:            435BFD7E229C2D0A79240C00C8AEB6B7
NOTE: Not after:         Jan  2 15:23:34 2027 GMT
NOTE: ACM certificate:   arn:aws:acm:us-east-1:<account>:certificate/<id>
NOTE: Key pair origin:   ACME
```

The page itself shows what Apache received from NGINX: Apache sees the client
as `127.0.0.1`, while `X-Real-IP`, `X-Forwarded-Proto`, the TLS protocol and
the cipher come from NGINX. It also shows the names, issuer, serial and dates
of the certificate NGINX is serving.

Check the certificate yourself from anywhere:

```bash
host=acme-lab.mikes-cloud-solutions.com
openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null |
  openssl x509 -noout -issuer -serial -enddate
```

The script then checks the six load balancer paths. Every one has to return
200 and come from the expected backend, or the script fails:

```
============================================================================
Scenario 2 - ALB, ACM certificate on the load balancer
============================================================================

ALB /http/    -> HTTP:80 -> backend A (option a)
NOTE: URL:               https://alb-lab.mikes-cloud-solutions.com/http/
NOTE: HTTP status:       200
NOTE: Backend:           plain
NOTE: Scheme at backend: http
NOTE: Front cert issuer: C=US, O=Amazon, CN=Amazon RSA 2048 S19
NOTE: NGINX saw client:  10.0.1.117
NOTE: X-Forwarded-For:   203.0.113.10

ALB /tls/     -> HTTPS:443 -> backend B (option b, expired)
NOTE: URL:               https://alb-lab.mikes-cloud-solutions.com/tls/
NOTE: HTTP status:       200
NOTE: Backend:           self-signed
NOTE: Scheme at backend: https
NOTE: Front cert issuer: C=US, O=Amazon, CN=Amazon RSA 2048 S19
NOTE: NGINX saw client:  10.0.1.52
NOTE: X-Forwarded-For:   203.0.113.10
NOTE: Backend cert:      CN = nobody-checks-this.invalid
NOTE: Backend not after: Jan  1 00:00:00 2025 GMT
NOTE: Backend cert is EXPIRED and wrong-name; the load balancer accepted it anyway.

ALB /tls10y/  -> HTTPS:443 -> backend C (option b, ten-year)
NOTE: URL:               https://alb-lab.mikes-cloud-solutions.com/tls10y/
NOTE: HTTP status:       200
NOTE: Backend:           self-signed-10y
NOTE: Scheme at backend: https
NOTE: Front cert issuer: C=US, O=Amazon, CN=Amazon RSA 2048 S19
NOTE: NGINX saw client:  10.0.1.117
NOTE: X-Forwarded-For:   203.0.113.10
NOTE: Backend cert:      CN = tls-backend.internal
NOTE: Backend not after: Nov 22 00:19:44 2036 GMT
NOTE: Backend cert is self-signed and in date; nothing has to renew it for years.

============================================================================
Scenario 3 - NLB, ACM certificate on the load balancer
============================================================================

NLB :443      -> TCP:80 -> backend A (option a)
NOTE: URL:               https://nlb-lab.mikes-cloud-solutions.com/
NOTE: HTTP status:       200
NOTE: Backend:           plain
NOTE: Scheme at backend: http
NOTE: Front cert issuer: C=US, O=Amazon, CN=Amazon RSA 2048 S19
NOTE: NGINX saw client:  203.0.113.10
NOTE: X-Forwarded-For:   (not set)

NLB :8443     -> TLS:443 -> backend B (option b, expired)
NOTE: URL:               https://nlb-lab.mikes-cloud-solutions.com:8443/
NOTE: HTTP status:       200
NOTE: Backend:           self-signed
NOTE: Scheme at backend: https
NOTE: Front cert issuer: C=US, O=Amazon, CN=Amazon RSA 2048 S19
NOTE: NGINX saw client:  203.0.113.10
NOTE: X-Forwarded-For:   (not set)
NOTE: Backend cert:      CN = nobody-checks-this.invalid
NOTE: Backend not after: Jan  1 00:00:00 2025 GMT
NOTE: Backend cert is EXPIRED and wrong-name; the load balancer accepted it anyway.

NLB :9443     -> TLS:443 -> backend C (option b, ten-year)
NOTE: URL:               https://nlb-lab.mikes-cloud-solutions.com:9443/
NOTE: HTTP status:       200
NOTE: Backend:           self-signed-10y
NOTE: Scheme at backend: https
NOTE: Front cert issuer: C=US, O=Amazon, CN=Amazon RSA 2048 S19
NOTE: NGINX saw client:  203.0.113.10
NOTE: X-Forwarded-For:   (not set)
NOTE: Backend cert:      CN = tls-backend.internal
NOTE: Backend not after: Nov 22 00:19:44 2036 GMT
NOTE: Backend cert is self-signed and in date; nothing has to renew it for years.
```

The front certificate (issued by Amazon for `alb-lab` and `nlb-lab`) is the
only one the client checks. Backend B's certificate is broken three ways and
both load balancers serve its page regardless; backend C's is the sane
ten-year version.

## Renew live

```bash
./renew.sh
```

This is what the 47-day world looks like when it works: a renewal nobody
notices. The script forces one `certbot renew` on the instance through SSM,
then shows the rotation while the site keeps serving:

```
NOTE: Serial before:   4170AEF27C762ECBC4EBDFA4A03F8BC6
NOTE: ACM ARN before:  arn:aws:acm:us-east-1:<account>:certificate/eb755a0c-…

NOTE: Forcing certbot renewal on i-0….
NOTE: certbot renewal succeeded.

NOTE: Serial after:    41DDF278F43C112E9A1D9E4D1F0519C4
NOTE: ACM ARN after:   arn:aws:acm:us-east-1:<account>:certificate/eb755a0c-…

NOTE: NGINX is serving the renewed certificate.
NOTE: ACM kept the same certificate ARN across the renewal.
NOTE: The page still loads: Served by Apache through NGINX.
```

Without `renew.sh`, Ubuntu's `certbot.timer` renews the 45-day certificate
automatically when it has 30 days left. No EAB is needed for renewals: certbot
reuses the ACME account it registered, which keeps working after the 1-day EAB
expires.

## Teardown

```bash
./destroy.sh
```

1. Revokes the certificate through the ACME endpoint (`certbot revoke`, via
   SSM), since its private key is about to be destroyed.
2. Destroys `03-lb/` (its ACM certificate and validation records are
   Terraform's own), then `02-server/`, then `01-acme/`. Deleting the endpoint
   also deletes its domain validation, and ACM removes the validation CNAME.
3. Tries to delete the lab's certificates from ACM. ACM refuses for ACME
   certificates that have not expired. They stay listed as `REVOKED` and are
   removed automatically a year after expiry.
4. Deletes any validation CNAME ACM left under `acme-lab`.

The hosted zone and its other records are never touched.

## Cost

* **ACM:** ACME certificates are billed **per domain name at issuance**, with
  volume tiers. Every `apply.sh` and every `renew.sh` is one issuance for one
  name. See [ACM pricing](https://aws.amazon.com/certificate-manager/pricing/).
* **EC2:** one `t3.micro`, an 8 GiB gp3 volume and an Elastic IP while the lab
  is up.
* **Phase 3, per hour while it is up:** an ALB and an NLB (about $0.0225 an
  hour each plus a small capacity-unit charge), a NAT gateway ($0.045 an hour
  plus $0.045 per GB through it), three more `t3.micro` instances (about
  $0.0104 an hour each) with 8 GiB volumes, and public IPv4 addresses for the
  load balancer nodes and the NAT gateway ($0.005 an hour each). Roughly
  $0.15 an hour in us-east-1; the NAT gateway is the biggest single line. The
  load balancer's ACM certificate is free.
* **Route 53:** the hosted zone you already have, plus queries.

## Files

| Path | Purpose |
|------|---------|
| `01-acme/acme.tf` | ACME endpoint, domain validation, EAB (`awscc`) |
| `01-acme/role.tf` | Issuer role ACM assumes, limited to the demo name |
| `02-server/network.tf` | VPC, public subnet, security group (443 only) |
| `02-server/role.tf` | Instance role: SSM + read this one EAB |
| `02-server/server.tf` | Ubuntu 24.04 instance, Elastic IP, A record |
| `02-server/scripts/userdata.sh.tpl` | Apache, certbot, deploy hook, NGINX |
| `03-lb/main.tf` | Inputs, including `backend_cert_mode` |
| `03-lb/network.tf` | Second VPC, public and private subnets, NAT gateway, ALB/NLB/backend security groups |
| `03-lb/cert.tf` | DNS-validated ACM certificate for `alb-lab` and `nlb-lab` |
| `03-lb/backends.tf` | Backend role (SSM only) and the three private Ubuntu 24.04 backends |
| `03-lb/alb.tf` | ALB, HTTPS listener, `/http/`, `/tls/` and `/tls10y/` rules, alias record |
| `03-lb/nlb.tf` | NLB, TLS:443, TLS:8443 and TLS:9443 listeners, alias record, outputs |
| `03-lb/scripts/backend.sh.tpl` | NGINX, diagnostic page, self-signed certificate |
| `lab.env` | The hosted zone name, sourced by the scripts and passed to Terraform |
| `apply.sh` / `validate.sh` / `renew.sh` / `destroy.sh` | Lab lifecycle |
| `make_diagram.py` | Regenerates `architecture-{light,dark}.svg` |

## Notes from building it

* **certbot comes from apt, not snap.** Ubuntu 24.04's certbot 2.9 already has
  `--eab-kid`, `--eab-hmac-key` and `--issuance-timeout`, and ships
  `certbot.timer`. The snap store refused connections during early boot often
  enough to break the build, so nothing here uses snap. The AWS CLI v2 comes
  from AWS's own installer.
* **Allow two minutes to issue.** ACM can take up to 120 seconds to issue, which
  is longer than many ACME clients wait by default; the lab passes
  `--issuance-timeout 120`.
* **The certificate has no subject CN.** The host name is only in the Subject
  Alternative Name, so the page and `validate.sh` show the SAN instead.
* **Keep TLS 1.2 on a TLS backend behind an NLB.** NLB HTTPS health checks
  fail against targets that only speak TLS 1.3. Backends B and C allow both.
* **An NLB's security group is a creation-time choice.** One created without a
  security group can never be given one, and then its targets have to allow
  the clients' own addresses.
* **Cross-zone load balancing is on for the NLB.** Each target group has a
  single instance in one Availability Zone; without cross-zone, the NLB node
  in the other zone would have no target.
