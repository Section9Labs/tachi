FROM swift:6.3-noble AS build
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev libssl-dev && rm -rf /var/lib/apt/lists/*
COPY Packages/TachiAccounts ./Packages/TachiAccounts
COPY Packages/TachiRuntime ./Packages/TachiRuntime
COPY Package.swift Package.resolved ./
RUN swift package resolve --force-resolved-versions
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --static-swift-stdlib --product tachi-coordinator \
    && install "$(swift build -c release --show-bin-path)/tachi-coordinator" /tachi-coordinator

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 libssl3t64 && rm -rf /var/lib/apt/lists/*
COPY --from=build /tachi-coordinator /usr/local/bin/tachi-coordinator
USER 65534:65534
EXPOSE 8743
ENTRYPOINT ["/usr/local/bin/tachi-coordinator"]
CMD ["--host", "0.0.0.0", "--port", "8743"]
