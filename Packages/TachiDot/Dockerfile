FROM swift:6.3-noble AS build
WORKDIR /src
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
RUN swift build -c release --product tachi-dot-plugin --force-resolved-versions -Xswiftc -warnings-as-errors \
    && install -m 0755 "$(swift build -c release --show-bin-path)/tachi-dot-plugin" /tachi-dot-plugin

FROM swift:6.3-noble-slim
RUN test -s /etc/ssl/certs/ca-certificates.crt || (apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*)
COPY --from=build /tachi-dot-plugin /usr/local/bin/tachi-dot-plugin
USER 65534:65534
ENV TACHI_DOT_RECEIPT_FILE=/var/lib/tachi-dot/receipt.json
ENTRYPOINT ["/usr/local/bin/tachi-dot-plugin"]
