FROM swift:6.3-noble AS build
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev libssl-dev libcurl4-openssl-dev && rm -rf /var/lib/apt/lists/*
COPY Packages/TachiAccounts ./Packages/TachiAccounts
COPY Packages/TachiRuntime ./Packages/TachiRuntime
COPY Packages/TachiGrok ./Packages/TachiGrok
COPY Package.swift Package.resolved ./
RUN swift package resolve --force-resolved-versions
COPY Sources ./Sources
COPY ServiceTests ./ServiceTests
RUN swift build -c release --static-swift-stdlib --product tachi-coordinator \
    && install "$(swift build -c release --show-bin-path)/tachi-coordinator" /tachi-coordinator
RUN swift build --package-path Packages/TachiAccounts -c release --static-swift-stdlib --product tachi-accounts \
    && install "$(swift build --package-path Packages/TachiAccounts -c release --show-bin-path)/tachi-accounts" /tachi-accounts

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends sqlite3 libssl3t64 libcurl4t64 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /tachi-coordinator /usr/local/bin/tachi-coordinator
COPY --from=build /tachi-accounts /usr/local/bin/tachi-accounts
RUN install -d -m 0700 -o 65534 -g 65534 /var/lib/tachi
USER 65534:65534
EXPOSE 8743
ENTRYPOINT ["/usr/local/bin/tachi-coordinator"]
CMD ["--host", "0.0.0.0", "--port", "8743"]
