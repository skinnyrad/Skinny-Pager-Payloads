#!/usr/bin/env python3
"""
v28_wispr.py — Captive portal / WISPr XML server.

Listens on 0.0.0.0:80 by default and serves captive-portal trust responses.

--wispr-mode flag controls the response strategy:

  apple-success   -> GET /hotspot-detect.html returns
                       <HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>
                     iOS marks network as "online" immediately. No Safari popup.
                     This is the DEFAULT. It matches what AT&T legacy attwifi
                     actually returns in the wild (Apple's expected body, not
                     WISPr XML). Per EAP-SUCCESS+Bridging.txt §"Phase 1", the
                     IE-221 OUI match + Apple Success body is what triggers
                     iOS auto-join on managed attwifi profiles.

  wispr-redirect  -> GET /hotspot-detect.html returns the WISPr <Redirect> XML
                     pointing LoginURL at /auth. iOS extracts LoginURL, POSTs
                     credentials to it. /auth returns the <AuthenticationReply>
                     with ResponseCode=50 (Login Success). Some iOS versions
                     open Safari during the redirect dance.

  wispr-auth-only -> /hotspot-detect.html returns 200 with no body. iOS treats
                     this as "captive portal detected" and opens Safari. Used
                     only for troubleshooting — iOS will never auto-join with
                     this mode.

  both            -> /hotspot-detect.html -> Apple Success body (auto-join path).
                     /wispr/redirect and /wispr/success return WISPr XML for
                     observability. Recommended for live tests.

  /generate_204   -> 204 (Apple's iOS 14+ probe endpoint).

Logs every request to --log with (ts, src_ip, path, response_kind).
"""

import argparse
import datetime
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

APPLE_SUCCESS_HTML = (
    b"<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
)

WISPR_REDIRECT_XML_TPL = """<?xml version="1.0" encoding="UTF-8"?>
<WISPAccessGatewayParam xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.wispzone.com/wispaccessgatewayparam.xsd">
  <Redirect>
    <AccessProcedure>1.0</AccessProcedure>
    <AccessLocation>ATT_Lab_Zone</AccessLocation>
    <LocationName>ATT_Network</LocationName>
    <LoginURL>http://{server_ip}:{port}/auth</LoginURL>
    <MessageType>100</MessageType>
    <ResponseCode>0</ResponseCode>
  </Redirect>
</WISPAccessGatewayParam>
"""

WISPR_SUCCESS_XML = b"""<?xml version="1.0" encoding="UTF-8"?>
<WISPAccessGatewayParam>
  <AuthenticationReply>
    <MessageType>120</MessageType>
    <ResponseCode>50</ResponseCode>
    <ReplyMessage>Authentication Success</ReplyMessage>
  </AuthenticationReply>
</WISPAccessGatewayParam>
"""


class WISPrHandler(BaseHTTPRequestHandler):
    server_version = "v28_wispr/1.0"

    def log_message(self, fmt, *args):
        return

    def _log(self, body_tag, body_excerpt=""):
        if not hasattr(self.server, "log_fp"):
            return
        ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        line = (
            f"[{ts}] {self.command} {self.path} from {self.client_address[0]} "
            f"-> {body_tag}"
        )
        if body_excerpt:
            line += f"  body={body_excerpt[:80]!r}"
        self.server.log_fp.write(line + "\n")
        self.server.log_fp.flush()

    def _send_html(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_xml(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_empty(self, status):
        self.send_response(status)
        self.end_headers()

    def do_GET(self):
        mode = self.server.wispr_mode

        if self.path.startswith("/generate_204"):
            self._send_empty(204)
            self._log("Apple-204-204")
            return

        if self.path.startswith("/wispr/redirect"):
            body = WISPR_REDIRECT_XML_TPL.format(
                server_ip=self.server.server_ip,
                port=self.server.server_port,
            ).encode("utf-8")
            self._send_xml(body)
            self._log("WISPr-Redirect-200")
            return

        if self.path.startswith("/wispr/success"):
            self._send_xml(WISPR_SUCCESS_XML)
            self._log("WISPr-Success-200")
            return

        if mode == "apple-success":
            self._send_html(APPLE_SUCCESS_HTML)
            self._log("Apple-Success-200", self.path)
            return

        if mode == "wispr-redirect":
            body = WISPR_REDIRECT_XML_TPL.format(
                server_ip=self.server.server_ip,
                port=self.server.server_port,
            ).encode("utf-8")
            self._send_xml(body)
            self._log("WISPr-Redirect-200", self.path)
            return

        if mode == "wispr-auth-only":
            self._send_empty(200)
            self._log("Auth-Only-200", self.path)
            return

        if mode == "both":
            self._send_html(APPLE_SUCCESS_HTML)
            self._log("Apple-Success-200", self.path)
            return

        self._send_html(APPLE_SUCCESS_HTML)
        self._log(f"FALLBACK-Apple-Success-200({mode})", self.path)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        body_excerpt = body[:80].decode("utf-8", "replace")
        self._send_html(APPLE_SUCCESS_HTML)
        self._log("Apple-Success-POST-200", body_excerpt)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=80,
                   help="iOS captive detection uses standard ports 80/443; "
                        "use 80 unless you have a specific reason otherwise")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--log", default="/tmp/v28_wispr.log")
    p.add_argument("--server-ip", default="127.0.0.1",
                   help="embedded in WISPr <LoginURL>; should be the IP a "
                        "client uses to reach this server (192.168.99.1 in "
                        "isolate mode, 172.16.52.1 in no-isolate)")
    p.add_argument("--wispr-mode", default="apple-success",
                   choices=["apple-success", "wispr-redirect",
                            "wispr-auth-only", "both"],
                   help="captive response strategy (default apple-success)")
    args = p.parse_args()

    print(f"[v28_wispr] opening log {args.log}", flush=True)
    log_fp = open(args.log, "a", buffering=1)
    log_fp.write(
        f"[{datetime.datetime.now()}] v28_wispr starting on "
        f"{args.bind}:{args.port} mode={args.wispr_mode}\n"
    )
    log_fp.flush()

    print(f"[v28_wispr] binding HTTPServer on {args.bind}:{args.port}", flush=True)
    srv = HTTPServer((args.bind, args.port), WISPrHandler)
    print(f"[v28_wispr] bound, setting attrs", flush=True)
    srv.log_fp = log_fp
    srv.server_ip = args.server_ip
    srv.server_port = args.port
    srv.wispr_mode = args.wispr_mode

    print(f"[v28_wispr] entering serve_forever mode={args.wispr_mode}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        log_fp.write(f"[{datetime.datetime.now()}] v28_wispr exiting\n")
        log_fp.close()


if __name__ == "__main__":
    main()
