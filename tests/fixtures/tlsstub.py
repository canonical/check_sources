#!/usr/bin/env python3
"""HTTPS stub for the TLS verification tests.

TLS behavior is per-listener, not per-path: the certificate is chosen at the
handshake, before any path exists. So unlike the consolidated plain-HTTP stub,
this one takes a certificate pair and serves 200 to everything; each test
starts one listener per certificate.

Usage: tlsstub.py PORTFILE CERTFILE KEYFILE [--close-first]

--close-first makes the listener accept and immediately close its first TCP
connection, before any handshake. That is a retryable transport failure to the
probe, and the certificate only appears on the second attempt: the sequence
observed in the field, where a connect timeout preceded a CERTNAME, and the
final label must be the certificate's, not the transport's.
"""
import http.server
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok\n")

    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()


class Server(http.server.HTTPServer):
    close_first = False
    closed_one = False

    def get_request(self):
        sock, addr = self.socket.accept()
        if self.close_first and not Server.closed_one:
            Server.closed_one = True
            sock.close()
            raise ConnectionAbortedError("closing the first connection")
        return self.context.wrap_socket(sock, server_side=True), addr


def main():
    portfile, certfile, keyfile = sys.argv[1:4]
    server = Server(("127.0.0.1", 0), Handler)
    server.close_first = "--close-first" in sys.argv[4:]
    server.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.context.load_cert_chain(certfile, keyfile)
    with open(portfile, "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
