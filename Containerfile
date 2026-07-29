FROM docker.io/library/alpine:3.20

RUN apk add --no-cache \
      dnsmasq \
      python3 \
      py3-pip \
      bind-tools \
      tini \
    && pip3 install --no-cache-dir --break-system-packages dnspython==2.6.1

COPY config/dnsmasq.conf /etc/dnsmasq.conf
COPY scripts/ddnsd.py /usr/local/bin/ddnsd.py
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/ddnsd.py /usr/local/bin/entrypoint.sh \
    && mkdir -p /data /keys /var/lib/misc \
    && touch /data/dynamic.conf /data/zone.json

EXPOSE 53/tcp 53/udp 5353/tcp 5353/udp

VOLUME ["/data", "/keys"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
