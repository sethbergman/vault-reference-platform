#!/usr/bin/env python3
"""Record Alertmanager webhook deliveries so tests can assert routing.

WHAT THIS IS FOR

This is not a stand-in for a pager. It exists so a test can ask a
question that Alertmanager's own API cannot answer: did this alert reach
the receiver the routing tree says it should?

Querying /api/v2/alerts proves an alert arrived at Alertmanager. It says
nothing about which receiver it was routed to, whether grouping collapsed
three nodes into one notification, or whether an inhibit rule suppressed
it. Those are properties of the delivery, so something has to be on the
receiving end to observe them.

Each receiver posts to its own path -- /page, /ticket, /default -- so the
path a delivery arrived on is the receiver that produced it.

WHAT IT DELIBERATELY DOES NOT DO

No retries, no auth, no persistence beyond a file. It is an observation
point for tests, and treating it as anything more would be a mistake.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SINK_DIR = os.environ.get("SINK_DIR", "/sink")
DELIVERIES = os.path.join(SINK_DIR, "deliveries.log")
PORT = int(os.environ.get("SINK_PORT", "9097"))

# Cap the body we will read. Alertmanager payloads are small; an
# unbounded read is a way to be wedged by anything that is not
# Alertmanager.
MAX_BODY = 1 << 20


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 - name fixed by BaseHTTPRequestHandler
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            self.send_response(413)
            self.end_headers()
            return

        raw = self.rfile.read(length) if length else b""

        # One line per delivery: the path it arrived on, then the payload
        # compacted onto a single line. Line-oriented so the tests can
        # grep and count rather than parse a stream.
        try:
            payload = json.loads(raw.decode("utf-8"))
            body = json.dumps(payload, separators=(",", ":"), sort_keys=True)
        except (ValueError, UnicodeDecodeError):
            # Record it anyway. A malformed delivery is a finding, and
            # dropping it would make the sink lie by omission.
            body = json.dumps({"unparsed": raw.decode("utf-8", "replace")})

        with open(DELIVERIES, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (self.path, body))
            fh.flush()
            os.fsync(fh.fileno())

        self.send_response(200)
        self.end_headers()

    def do_GET(self):  # noqa: N802
        # Readiness only. The deliveries file is read through the
        # container, not served, so the sink exposes nothing it does not
        # need to.
        self.send_response(200 if self.path == "/health" else 404)
        self.end_headers()

    def log_message(self, fmt, *args):
        # Default logging writes to stderr per request, which buries the
        # compose output the tests read.
        pass


if __name__ == "__main__":
    os.makedirs(SINK_DIR, exist_ok=True)
    # Create it up front so a test that reads before any alert fires sees
    # an empty file rather than a missing one -- "nothing was delivered"
    # and "the sink never started" must not look the same.
    open(DELIVERIES, "a", encoding="utf-8").close()
    sys.stderr.write("alert-sink listening on %d\n" % PORT)
    sys.stderr.flush()
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
