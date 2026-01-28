#!/usr/bin/env python3
"""Simple HTTP->HTTPS redirector.

Listens on the configured port (default 80) and redirects all requests to the
same host on the configured HTTPS port (default 8800) preserving path/query.

Run as root (to bind low ports). This is intentionally tiny and suitable for
simple appliance deployments. For production, prefer a full-featured proxy.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import argparse
import urllib.parse

class RedirectHandler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(307)
        self.send_header('Location', self._target_url())
        self.end_headers()

    def do_GET(self):
        self.send_response(307)
        self.send_header('Location', self._target_url())
        self.end_headers()

    def do_POST(self):
        self.send_response(307)
        self.send_header('Location', self._target_url())
        self.end_headers()

    def _target_url(self):
        host = self.headers.get('Host') or f"{self.server.server_address[0]}"
        # Preserve hostname, but replace port with HTTPS port
        parsed = urllib.parse.urlsplit(f"//{host}{self.path}")
        hostname = parsed.hostname
        path = parsed.path or '/'
        if parsed.query:
            path = path + '?' + parsed.query
        target = f"https://{hostname}:{self.server.https_port}{path}"
        return target

    def log_message(self, format, *args):
        # reduce noise
        pass


def run(listen: str, listen_port: int, https_port: int):
    server_address = (listen, listen_port)
    handler = RedirectHandler
    httpd = HTTPServer(server_address, handler)
    httpd.https_port = https_port
    print(f"HTTP->HTTPS redirector listening on {listen}:{listen_port} -> https port {https_port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--listen', default='0.0.0.0')
    p.add_argument('--listen-port', type=int, default=80)
    p.add_argument('--https-port', type=int, default=8800)
    args = p.parse_args()
    run(args.listen, args.listen_port, args.https_port)
