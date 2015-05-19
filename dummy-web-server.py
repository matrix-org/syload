#!/usr/bin/env python
"""
Very simple HTTP server in python.

Usage::
    ./dummy-web-server.py [<port>]

Send a GET request::
    curl http://localhost

Send a HEAD request::
    curl -I http://localhost

Send a POST request::
    curl -d "foo=bar&bin=baz" http://localhost

"""
from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer
import SocketServer
import json

class S(BaseHTTPRequestHandler):

    def _set_headers(self, body):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()

    def do_GET(self):
        body = json.dumps({"path": self.path})
        self._set_headers(body)
        self.wfile.write(body)

    def do_HEAD(self):
        self._set_headers()

    def do_POST(self):
        body = json.dumps({"path": self.path})
        self._set_headers(body)
        self.wfile.write(body)


def run(server_class=HTTPServer, handler_class=S, port=80):
    server_address = ('', port)
    httpd = server_class(server_address, handler_class)
    print 'Starting httpd...'
    httpd.serve_forever()

if __name__ == "__main__":
    from sys import argv

    if len(argv) == 2:
        run(port=int(argv[1]))
    else:
        run()
