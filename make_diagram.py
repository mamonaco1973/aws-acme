#!/usr/bin/env python3
"""Generate the README architecture diagram, one SVG per colour scheme.

Two files rather than one self-switching file: GitHub strips <style> blocks
from inline SVG, so a `prefers-color-scheme` media query inside the document
is silently dropped. The README pairs them with <picture>, which GitHub does
honour.

  architecture-{light,dark}.svg — top: the visitor, Route 53, the NGINX +
                                  Apache server with certbot, and the ACM ACME
                                  endpoint, binding and certificate inventory.
                                  Bottom (phase 3): the ALB and NLB with their
                                  ACM certificate, the plain, expired
                                  self-signed and ten-year self-signed
                                  backends behind both in private subnets,
                                  and their NAT gateway.

Run:  python make_diagram.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))

FONT = "-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif"

THEMES = {
    "dark": {
        "bg": "#0d1117", "panel": "#161b22", "text": "#e6edf3",
        "muted": "#8b949e", "line": "#58a6ff", "rule": "#30363d",
        "purple": "#c39be8", "green": "#3fb950", "blue": "#58a6ff",
        "amber": "#f2c163", "red": "#ff7b72", "navy": "#c8d6e8",
        "pink": "#f778ba",
    },
    "light": {
        "bg": "#ffffff", "panel": "#f6f8fa", "text": "#1f2328",
        "muted": "#59636e", "line": "#0969da", "rule": "#d1d9e0",
        "purple": "#8250df", "green": "#1a7f37", "blue": "#0969da",
        "amber": "#9a6700", "red": "#cf222e", "navy": "#475467",
        "pink": "#bf3989",
    },
}

# Lucide icon paths, on a 24-unit grid.
ICONS = {
    "globe": ['<circle cx="12" cy="12" r="10"/>',
              '<path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/>',
              '<path d="M2 12h20"/>'],
    "signpost": ['<path d="M12 13v8"/>', '<path d="M12 3v3"/>',
                 '<path d="M18 6a2 2 0 0 1 1.387.56l2.307 2.22a1 1 0 0 1 0 '
                 '1.44l-2.307 2.22A2 2 0 0 1 18 13H6a2 2 0 0 1-1.387-.56l-2.306'
                 '-2.22a1 1 0 0 1 0-1.44l2.306-2.22A2 2 0 0 1 6 6z"/>'],
    "lock": ['<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/>',
             '<path d="M7 11V7a5 5 0 0 1 10 0v4"/>'],
    "server": ['<rect width="20" height="8" x="2" y="2" rx="2" ry="2"/>',
               '<rect width="20" height="8" x="2" y="14" rx="2" ry="2"/>',
               '<line x1="6" x2="6.01" y1="6" y2="6"/>',
               '<line x1="6" x2="6.01" y1="18" y2="18"/>'],
    "refresh": ['<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/>',
                '<path d="M21 3v5h-5"/>',
                '<path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/>',
                '<path d="M8 16H3v5"/>'],
    "badge": ['<path d="M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 '
              '0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 '
              '1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z"/>',
              '<path d="m9 12 2 2 4-4"/>'],
    "key": ['<path d="m15.5 7.5 2.3 2.3a1 1 0 0 0 1.4 0l2.1-2.1a1 1 0 0 0 '
            '0-1.4L19 4"/>', '<path d="m21 2-9.6 9.6"/>',
            '<circle cx="7.5" cy="15.5" r="5.5"/>'],
    "split": ['<path d="M16 3h5v5"/>', '<path d="M8 3H3v5"/>',
              '<path d="M12 22v-8.3a4 4 0 0 0-1.172-2.872L3 3"/>',
              '<path d="m15 9 6-6"/>'],
    "network": ['<rect x="16" y="16" width="6" height="6" rx="1"/>',
                '<rect x="2" y="16" width="6" height="6" rx="1"/>',
                '<rect x="9" y="2" width="6" height="6" rx="1"/>',
                '<path d="M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3"/>',
                '<path d="M12 12V8"/>'],
    "files": ['<path d="M20 7h-3a2 2 0 0 1-2-2V2"/>',
              '<path d="M9 18a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h7l4 4v10a2 2 0 0 '
              '1-2 2Z"/>', '<path d="M3 7.6v12.8A1.6 1.6 0 0 0 4.6 22h9.8"/>'],
}


def _esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ================================================================================
# Layout
# ================================================================================

AW, AH = 1860, 1600
NH = 96                                    # node height
TITLE_PX, SUB_PX, EDGE_PX = 24, 16, 16

AWS_BOX = (380, 30, 1440, 1540)            # x, y, w, h
EC2_BOX = (420, 250, 650, 440)
LB_BOX = (420, 760, 1360, 780)             # phase 3: its own VPC

# id: (x, y, width, colour key, icon, title, subtitle)
NODES = {
    "visitor":  (40, 330, 290, "purple", "globe", "Browser",
                 "https://acme-lab…"),
    "route53":  (420, 90, 380, "navy", "signpost", "Route 53",
                 "A + alias records · validation CNAMEs"),
    "nginx":    (450, 330, 280, "green", "lock", "NGINX :443",
                 "TLS + reverse proxy"),
    "apache":   (760, 330, 280, "red", "server", "Apache",
                 "127.0.0.1:8080"),
    "certbot":  (450, 550, 590, "amber", "refresh", "certbot",
                 "ACME client · private key stays here"),
    "endpoint": (1200, 90, 580, "blue", "badge", "ACM ACME endpoint",
                 "pre-approved domain · Amazon Trust Services"),
    "eab":      (1200, 300, 420, "pink", "key", "External account binding",
                 "issuer role, acme-lab only"),
    "acm":      (1200, 550, 580, "blue", "files", "ACM certificates",
                 "45-day · key pair origin ACME"),
    # Phase 3
    "visitor2": (40, 1060, 290, "purple", "globe", "Browser",
                 "https://alb-lab… / nlb-lab…"),
    "alb":      (450, 840, 360, "green", "split", "ALB :443",
                 "HTTPS · path routing"),
    "lbcert":   (450, 1060, 360, "blue", "files", "ACM certificate",
                 "DNS-validated · auto-renewed"),
    "nlb":      (450, 1280, 360, "amber", "network", "NLB :443 · :8443 · :9443",
                 "TLS listeners"),
    "plain":    (1290, 840, 440, "navy", "server", "Backend A · NGINX :80",
                 "plain HTTP (option a)"),
    "selfsig":  (1290, 1060, 440, "red", "server", "Backend B · NGINX :443",
                 "self-signed · expired · wrong name"),
    "tenyear":  (1290, 1280, 440, "green", "server", "Backend C · NGINX :443",
                 "self-signed · ten years (option b)"),
    "nat":      (450, 1420, 360, "navy", "network", "NAT gateway",
                 "public subnet · outbound only"),
}


def _r(nid):
    """Return (left, top, right, bottom, centre-x, centre-y) for a node."""
    x, y, w = NODES[nid][0], NODES[nid][1], NODES[nid][2]
    return x, y, x + w, y + NH, x + w / 2, y + NH / 2


_EP_L = _r("endpoint")[0]
_ALB_R, _NLB_R = _r("alb")[2], _r("nlb")[2]
_BK_L = _r("plain")[0] - 5                 # all backends share a left edge
_ALB_Y, _NLB_Y = _r("alb")[5], _r("nlb")[5]
_ALB_TRUNK, _NLB_TRUNK = 1130, 1010
_V2_R, _V2_Y = _r("visitor2")[2], _r("visitor2")[5]
_CB_R = _r("certbot")[2]
_VIS_CX = _r("visitor")[4]

# id: (path, colour key, label, label_x, label_y, anchor, dashed)
EDGES = {
    "e_dns":     (f"M{_VIS_CX},{_r('visitor')[1]} V{_r('route53')[5]} "
                  f"H{_r('route53')[0] - 5}", "navy", "DNS lookup",
                  _VIS_CX + 12, 220, "start", True),
    "e_https":   (f"M{_r('visitor')[2]},{_r('nginx')[5]} "
                  f"L{_r('nginx')[0] - 5},{_r('nginx')[5]}", "purple", "HTTPS",
                  (_r("visitor")[2] + _r("nginx")[0]) / 2, _r("nginx")[5] - 14,
                  "middle", False),
    "e_proxy":   (f"M{_r('nginx')[2]},{_r('nginx')[5]} "
                  f"L{_r('apache')[0] - 5},{_r('nginx')[5]}", "green", "", 0, 0,
                  "start", False),
    "e_reload":  (f"M{_r('nginx')[4]},{_r('certbot')[1]} "
                  f"L{_r('nginx')[4]},{_r('nginx')[3] + 5}", "amber",
                  "deploy hook: reload", _r("nginx")[4] + 14,
                  (_r("nginx")[3] + _r("certbot")[1]) / 2 + 6, "start", True),
    "e_cname":   (f"M{_EP_L},118 L{_r('route53')[2] + 5},118", "blue",
                  "writes validation CNAME (once)",
                  (_EP_L + _r("route53")[2]) / 2, 106, "middle", True),
    "e_order":   (f"M{_CB_R},572 H1100 V162 H{_EP_L - 5}", "amber",
                  "ACME order + CSR", 1110, 236, "start", False),
    "e_eab":     (f"M{_CB_R},620 H1150 V{_r('eab')[5]} H{_r('eab')[0] - 5}",
                  "pink", "EAB key ID + MAC (once)", 1160, 476, "start", False),
    "e_issue":   (f"M1720,{_r('endpoint')[3]} L1720,{_r('acm')[1] - 5}",
                  "blue", "issued certs", 1710, 470, "end", False),
    # Phase 3
    "e_nat":     (f"M{_r('tenyear')[4]},{_r('tenyear')[3]} "
                  f"V{_r('nat')[5]} H{_r('nat')[2] + 5}", "navy",
                  "backends' only way out: apt + SSM", _r("tenyear")[4] - 12,
                  _r("nat")[5] - 12, "end", True),
    "e_v2alb":   (f"M{_V2_R},{_V2_Y - 20} H372 V{_ALB_Y} H{_r('alb')[0] - 5}",
                  "purple", "HTTPS", 362, 990, "end", False),
    "e_v2nlb":   (f"M{_V2_R},{_V2_Y + 20} H372 V{_NLB_Y} H{_r('nlb')[0] - 5}",
                  "purple", "TLS", 362, 1200, "end", False),
    "e_certalb": (f"M{_r('lbcert')[4]},{_r('lbcert')[1]} "
                  f"V{_r('alb')[3] + 5}", "blue", "", 0, 0, "start", True),
    "e_certnlb": (f"M{_r('lbcert')[4]},{_r('lbcert')[3]} "
                  f"V{_r('nlb')[1] - 5}", "blue", "", 0, 0, "start", True),
    "e_albA":    (f"M{_ALB_R},{_ALB_Y - 24} H{_ALB_TRUNK} "
                  f"V{_r('plain')[5] - 24} H{_BK_L}", "green", "/http/*",
                  _BK_L - 8, _r("plain")[5] - 32, "end", False),
    "e_nlbA":    (f"M{_NLB_R},{_NLB_Y + 24} H{_NLB_TRUNK} "
                  f"V{_r('plain')[5] + 24} H{_BK_L}", "amber", "TLS :443",
                  _BK_L - 8, _r("plain")[5] + 44, "end", False),
    "e_albB":    (f"M{_ALB_R},{_ALB_Y - 24} H{_ALB_TRUNK} "
                  f"V{_r('selfsig')[5] - 24} H{_BK_L}", "green", "/tls/*",
                  _BK_L - 8, _r("selfsig")[5] - 32, "end", False),
    "e_nlbB":    (f"M{_NLB_R},{_NLB_Y + 24} H{_NLB_TRUNK} "
                  f"V{_r('selfsig')[5] + 24} H{_BK_L}", "amber", "TLS :8443",
                  _BK_L - 8, _r("selfsig")[5] + 44, "end", False),
    "e_albC":    (f"M{_ALB_R},{_ALB_Y - 24} H{_ALB_TRUNK} "
                  f"V{_r('tenyear')[5] - 24} H{_BK_L}", "green", "/tls10y/*",
                  _BK_L - 8, _r("tenyear")[5] - 32, "end", False),
    "e_nlbC":    (f"M{_NLB_R},{_NLB_Y + 24} H{_NLB_TRUNK} "
                  f"V{_r('tenyear')[5] + 24} H{_BK_L}", "amber", "TLS :9443",
                  _BK_L - 8, _r("tenyear")[5] + 44, "end", False),
}


def node_svg(nid, t):
    """Render one service box: rounded panel, icon, title, subtitle."""
    x, y, w, key, icon, title, sub = NODES[nid]
    colour = t[key]
    scale = 1.25
    isz = 24 * scale
    ix, iy = x + 20, y + (NH - isz) / 2
    tx = x + 20 + isz + 14
    return "".join([
        f'<rect x="{x}" y="{y}" width="{w}" height="{NH}" rx="10" ry="10" '
        f'fill="{t["panel"]}" stroke="{colour}" stroke-width="2"/>',
        f'<g transform="translate({ix},{iy}) scale({scale})" fill="none" '
        f'stroke="{colour}" stroke-width="2" stroke-linecap="round" '
        f'stroke-linejoin="round">' + "".join(ICONS[icon]) + "</g>",
        f'<text x="{tx}" y="{y + NH/2 - 4}" font-family="{FONT}" '
        f'font-size="{TITLE_PX}" font-weight="600" fill="{t["text"]}">{title}</text>',
        f'<text x="{tx}" y="{y + NH/2 + 22}" font-family="{FONT}" '
        f'font-size="{SUB_PX}" fill="{t["muted"]}">{_esc(sub)}</text>',
    ])


def edge_svg(eid, t):
    """Render one arrow plus its label."""
    d, key, label, lx, ly, anchor, dashed = EDGES[eid]
    colour = t[key]
    dash = ' stroke-dasharray="7 6"' if dashed else ""
    out = (f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="2"'
           f'{dash} marker-end="url(#a_{eid})"/>')
    if label:
        out += (f'<text x="{lx}" y="{ly}" text-anchor="{anchor}" '
                f'font-family="{FONT}" font-size="{EDGE_PX}" font-weight="600" '
                f'fill="{colour}">{_esc(label)}</text>')
    return out


def _box(box, label, t, dashed):
    x, y, w, h = box
    dash = ' stroke-dasharray="10 8"' if dashed else ""
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" '
            f'fill="none" stroke="{t["rule"]}" stroke-width="2"{dash}/>'
            f'<text x="{x + 20}" y="{y + 30}" font-family="{FONT}" '
            f'font-size="18" font-weight="600" fill="{t["muted"]}">'
            f'{_esc(label)}</text>')


def build_architecture(t):
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{AW}" height="{AH}" '
           f'viewBox="0 0 {AW} {AH}" role="img" '
           f'aria-label="A browser reaches NGINX on an EC2 instance over HTTPS; '
           f'NGINX proxies to Apache. certbot on the instance gets the '
           f'certificate from the ACM ACME endpoint, which approved the domain '
           f'through a Route 53 CNAME. Below, an ALB and an NLB end TLS with a '
           f'regular ACM certificate and forward to a plain HTTP backend and '
           f'to a backend with an expired self-signed certificate">', "<defs>"]
    # One marker per edge: a shared marker cannot carry per-edge colour.
    for eid, spec in EDGES.items():
        out.append(
            f'<marker id="a_{eid}" viewBox="0 0 10 10" refX="9" refY="5" '
            f'markerWidth="5" markerHeight="5" orient="auto-start-reverse">'
            f'<path d="M0,0 L10,5 L0,10 z" fill="{t[spec[1]]}"/></marker>')
    out.append("</defs>")
    out.append(f'<rect width="{AW}" height="{AH}" fill="{t["bg"]}"/>')

    out.append(_box(AWS_BOX, "AWS · us-east-1", t, dashed=True))
    out.append(_box(EC2_BOX, "EC2 · Ubuntu 24.04 · Elastic IP", t, dashed=False))
    out.append(_box(LB_BOX, "Phase 3 · own VPC · LBs and NAT public, backends private", t, dashed=False))
    # The point of phase 3, under the TLS backend.
    bx, by = _r("selfsig")[0], _r("selfsig")[3]
    out.append(f'<text x="{bx}" y="{by + 34}" font-family="{FONT}" '
               f'font-size="{EDGE_PX}" font-weight="600" fill="{t["red"]}">'
               f'Neither load balancer checks this certificate</text>')

    for eid in EDGES:
        out.append(edge_svg(eid, t))
    for nid in NODES:
        out.append(node_svg(nid, t))
    out.append("</svg>")
    return "".join(out)


def main():
    for name, theme in THEMES.items():
        path = os.path.join(HERE, f"architecture-{name}.svg")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(build_architecture(theme))
        print(f"  architecture-{name}.svg")


if __name__ == "__main__":
    main()
