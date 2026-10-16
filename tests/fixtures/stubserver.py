#!/usr/bin/env python3
"""Consolidated stub server for the bats suite.

One server stands in for every behavior the tests need, selected by the first
path segment of the repository (OCI) or the request path (generic probes).
Binds port 0 so parallel test runs never collide; writes the chosen port to
the file given as argv[1] and a "METHOD PATH USER-AGENT" line per request to
the log file given as argv[2].

OCI behaviors, by repository prefix (source: http://HOST/<behavior>/x/y:1|oci):
  ok           401 challenge with realm, service and scope; token; single-arch
               manifest; ranged blob answered 206
  anon         anonymous multi-arch index, so the probe takes the architecture
               hop, then the blob
  noscope      challenge without scope; the token endpoint requires the
               synthesized repository scope to be present
  hostile      challenge whose scope carries a space and an ampersand; the
               token endpoint requires that exact value, decoded
  ratelimit    manifest answers 429
  stall        token endpoint accepts the connection and never answers
  redirdead    anonymous manifest; blob redirects to a dead port

Generic behaviors, by path:
  /g200        HEAD answers 200
  /g404        HEAD answers 404
  /gredir      HEAD answers 302 to /g200 on the same host
  /gslow       sleeps 0.3s then answers 200, for the concurrency test
  /peak        GET answers the highest number of concurrent in-flight
               requests seen so far, as text
"""
import http.server
import json
import sys
import threading
import time

DIGEST = "sha256:" + "ab" * 32
BLOB = b"x" * 100
MANIFEST = json.dumps(
    {"schemaVersion": 2, "layers": [{"digest": DIGEST, "size": len(BLOB)}]}
).encode()
INDEX = json.dumps(
    {
        "schemaVersion": 2,
        "manifests": [
            {"digest": DIGEST, "platform": {"architecture": "amd64"}}
        ],
    }
).encode()
HOSTILE_SCOPE = "repository:hostile/x/y:pull more&stuff"

lock = threading.Lock()
in_flight = 0
peak = 0


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _log_request(self):
        with open(sys.argv[2], "a") as f:
            f.write(
                "%s %s %s\n"
                % (self.command, self.path, self.headers.get("User-Agent", "-"))
            )

    def _behavior(self):
        # /v2/<behavior>/.../manifests/<tag> or /v2/<behavior>/.../blobs/<d>
        parts = self.path.split("/")
        return parts[2] if len(parts) > 2 and parts[1] == "v2" else ""

    def _challenge(self, scope):
        self.send_response(401)
        value = (
            'Bearer realm="http://%s/token",service="stub"'
            % self.headers["Host"]
        )
        if scope is not None:
            value += ',scope="%s"' % scope
        self.send_header("WWW-Authenticate", value)
        self.end_headers()

    def do_GET(self):
        self._log_request()
        from urllib.parse import parse_qs, urlparse

        if self.path.startswith("/token"):
            q = parse_qs(urlparse(self.path).query)
            scope = q.get("scope", [""])[0]
            if "stall" in scope:
                time.sleep(120)
                return
            if "hostile" in scope and scope != HOSTILE_SCOPE:
                self.send_response(403)
                self.end_headers()
                return
            if "noscope" in scope and not scope.startswith("repository:"):
                self.send_response(403)
                self.end_headers()
                return
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"token":"tk"}')
            return

        if self.path == "/peak":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(str(peak).encode())
            return

        behavior = self._behavior()
        if "/manifests/" in self.path:
            if behavior == "ratelimit":
                self.send_response(429)
                self.end_headers()
                return
            if behavior in ("anon", "redirdead"):
                self.send_response(200)
                self.end_headers()
                # The multi-arch index for anon makes the probe take the
                # architecture hop; the hop asks for the digest and gets
                # the single-arch manifest.
                if behavior == "anon" and DIGEST not in self.path:
                    self.wfile.write(INDEX)
                else:
                    self.wfile.write(MANIFEST)
                return
            if not self.headers.get("Authorization"):
                repo = "/".join(self.path.split("/")[2:-2])
                if behavior == "noscope":
                    self._challenge(None)
                elif behavior == "hostile":
                    self._challenge(HOSTILE_SCOPE)
                else:
                    self._challenge("repository:%s:pull" % repo)
                return
            self.send_response(200)
            self.end_headers()
            self.wfile.write(MANIFEST)
            return

        if "/blobs/" in self.path:
            if behavior == "redirdead":
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:9/cdn/blob")
                self.end_headers()
                return
            self.send_response(206)
            self.end_headers()
            self.wfile.write(BLOB)
            return

        self.send_response(404)
        self.end_headers()

    def do_HEAD(self):
        global in_flight, peak
        self._log_request()
        if self.path == "/g200":
            self.send_response(200)
            self.end_headers()
            return
        if self.path == "/g404":
            self.send_response(404)
            self.end_headers()
            return
        if self.path == "/gredir":
            self.send_response(302)
            self.send_header(
                "Location", "http://%s/g200" % self.headers["Host"]
            )
            self.end_headers()
            return
        if self.path.startswith("/gslow"):
            with lock:
                in_flight += 1
                peak = max(peak, in_flight)
            time.sleep(0.3)
            with lock:
                in_flight -= 1
            self.send_response(200)
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
