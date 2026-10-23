#!/usr/bin/env python3
"""Minimal WebDAV server to synchronize Rnote Mobile with a folder on the PC.

Serves the `.rnote` files of one folder on the local network. Rnote on the PC
opens and saves the files of that folder directly, the mobile app synchronizes
with it (Ajustes > Sincronización).

Only the Python standard library is needed:

    python3 rnote_sync_server.py ~/Documentos/Rnote --user yo --password secreto

Then enter the printed URL in the app. Without --user/--password anybody on
the local network can read and write the folder.
"""

import argparse
import base64
import email.utils
import hmac
import html
import os
import socket
import sys
import tempfile
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = ""
AUTH = None  # expected "Authorization" header value


def etag_of(st):
    return '"%x-%x"' % (st.st_mtime_ns, st.st_size)


class Handler(BaseHTTPRequestHandler):
    server_version = "RnoteSync/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s  %s\n" % (self.address_string(), fmt % args))

    # -- helpers -------------------------------------------------------------

    def _authorized(self):
        if AUTH is None:
            return True
        got = self.headers.get("Authorization", "")
        if hmac.compare_digest(got.encode(), AUTH.encode()):
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Rnote"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def _path(self):
        """Maps the request path to a file in ROOT, or None if outside."""
        rel = urllib.parse.unquote(urllib.parse.urlparse(self.path).path).lstrip("/")
        full = os.path.realpath(os.path.join(ROOT, rel))
        if full != ROOT and not full.startswith(ROOT + os.sep):
            return None
        return full

    def _reply(self, code, body=b"", content_type="text/plain; charset=utf-8", headers=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length > 0 else b""

    # -- methods -------------------------------------------------------------

    def do_OPTIONS(self):
        self._reply(200, headers={
            "DAV": "1",
            "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, MKCOL",
        })

    def do_PROPFIND(self):
        if not self._authorized():
            return
        self._read_body()
        path = self._path()
        if path is None or not os.path.exists(path):
            return self._reply(404)
        depth = self.headers.get("Depth", "1")
        entries = [path]
        if os.path.isdir(path) and depth != "0":
            entries += [os.path.join(path, n) for n in sorted(os.listdir(path)) if not n.startswith(".")]
        parts = ['<?xml version="1.0" encoding="utf-8"?>\n<d:multistatus xmlns:d="DAV:">']
        for p in entries:
            st = os.stat(p)
            rel = os.path.relpath(p, ROOT)
            href = "/" if rel == "." else "/" + urllib.parse.quote(rel.replace(os.sep, "/"))
            if os.path.isdir(p) and not href.endswith("/"):
                href += "/"
            props = "<d:getlastmodified>%s</d:getlastmodified>" % email.utils.formatdate(st.st_mtime, usegmt=True)
            if os.path.isdir(p):
                props += "<d:resourcetype><d:collection/></d:resourcetype>"
            else:
                props += "<d:resourcetype/><d:getcontentlength>%d</d:getcontentlength>" % st.st_size
                props += "<d:getetag>%s</d:getetag>" % html.escape(etag_of(st))
            parts.append(
                "<d:response><d:href>%s</d:href><d:propstat><d:prop>%s</d:prop>"
                "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>" % (html.escape(href), props)
            )
        parts.append("</d:multistatus>")
        self._reply(207, "".join(parts).encode(), "application/xml; charset=utf-8")

    def do_GET(self):
        if not self._authorized():
            return
        path = self._path()
        if path is None or not os.path.isfile(path):
            if path == ROOT:
                names = [n for n in sorted(os.listdir(ROOT)) if n.endswith(".rnote")]
                body = ("Rnote sync: %d documentos\n\n" % len(names) + "\n".join(names)).encode()
                return self._reply(200, body)
            return self._reply(404)
        with open(path, "rb") as f:
            data = f.read()
        self._reply(200, data, "application/octet-stream", {"ETag": etag_of(os.stat(path))})

    do_HEAD = do_GET

    def do_PUT(self):
        if not self._authorized():
            return
        path = self._path()
        if path is None or path == ROOT:
            return self._reply(403)
        data = self._read_body()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        existed = os.path.exists(path)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".upload-")
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
        self._reply(204 if existed else 201, headers={"ETag": etag_of(os.stat(path))})

    def do_DELETE(self):
        if not self._authorized():
            return
        path = self._path()
        if path is None or path == ROOT:
            return self._reply(403)
        if not os.path.exists(path):
            return self._reply(404)
        if os.path.isdir(path):
            return self._reply(403)
        os.remove(path)
        self._reply(204)

    def do_MKCOL(self):
        if not self._authorized():
            return
        path = self._path()
        if path is None:
            return self._reply(403)
        if os.path.exists(path):
            return self._reply(405)
        os.makedirs(path)
        self._reply(201)


def lan_address():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main():
    global ROOT, AUTH
    parser = argparse.ArgumentParser(description="Sincroniza una carpeta de Rnote con Rnote Mobile (WebDAV).")
    parser.add_argument("folder", nargs="?", default=".", help="carpeta con los archivos .rnote")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--user")
    parser.add_argument("--password")
    args = parser.parse_args()

    ROOT = os.path.realpath(os.path.expanduser(args.folder))
    os.makedirs(ROOT, exist_ok=True)
    if args.user:
        token = base64.b64encode(("%s:%s" % (args.user, args.password or "")).encode()).decode()
        AUTH = "Basic " + token

    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    print("Carpeta: %s" % ROOT)
    print("URL para la app: http://%s:%d/" % (lan_address(), args.port))
    if AUTH is None:
        print("Aviso: sin usuario/contraseña, cualquiera en la red local puede acceder.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
