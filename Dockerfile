FROM swift:6.3-noble AS build
WORKDIR /src
COPY Package.swift Package.resolved ./
RUN swift package resolve --force-resolved-versions
COPY Sources ./Sources
RUN swift build -c release --static-swift-stdlib --product tachi-coordinator \
    && install "$(swift build -c release --show-bin-path)/tachi-coordinator" /tachi-coordinator

FROM ubuntu:24.04
COPY --from=build /tachi-coordinator /usr/local/bin/tachi-coordinator
USER 65534:65534
EXPOSE 8743
ENTRYPOINT ["/usr/local/bin/tachi-coordinator"]
CMD ["--host", "0.0.0.0", "--port", "8743"]
