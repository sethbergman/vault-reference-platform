# Records Alertmanager webhook deliveries so tests can assert which
# receiver an alert was routed to. See sink.py for why that needs a
# receiving end at all.
FROM python:3.12-alpine

COPY sink.py /usr/local/bin/sink.py
RUN chmod +x /usr/local/bin/sink.py

# Not root. Same reasoning as the audit collector: this holds a network
# listener, and there is no reason for it to hold privileges too.
#
# /sink is created and owned here rather than left to Docker, because an
# empty named volume inherits the ownership of the image directory it is
# mounted over. That applies only to a fresh volume -- one created by an
# earlier root-owned build stays root-owned until `compose down -v`.
RUN addgroup -S sink \
    && adduser -S -G sink -h /sink sink \
    && mkdir -p /sink \
    && chown sink:sink /sink

USER sink

EXPOSE 9097
ENTRYPOINT ["python3", "/usr/local/bin/sink.py"]
