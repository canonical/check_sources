#!/usr/bin/env python3
"""Logging forward proxy for the bats suite.

Plain-HTTP proxying only: the client sends the absolute URI, the proxy
forwards it and relays the answer, including HTTP error statuses, which
urllib raises as exceptions and a naive relay would turn into a dropped
connection. Binds port 0; writes the port to argv[1] and one absolute URI
per proxied request to argv[2]. A request that reaches the origin without
appearing in that log went around the proxy, which is what the suite uses
it to detect.
"""
import http.server
import sys
import urllib.error
import urllib.request


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(sys.argv[2], "a") as f:
            f.write(self.path.split("?")[0] + "\n")
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in ("host", "proxy-connection")
        }
        req = urllib.request.Request(self.path, headers=headers)
        try:
            resp = urllib.request.urlopen(req)
            status = resp.status
        except urllib.error.HTTPError as err:
            resp = err
            status = err.code
        body = resp.read()
        self.send_response(status)
        for k, v in resp.headers.items():
            if k.lower() not in ("transfer-encoding", "connection"):
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
