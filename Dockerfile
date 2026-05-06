FROM debian:bookworm-slim AS builder
RUN apt-get update && apt-get install -y wget xz-utils && rm -rf /var/lib/apt/lists/*
RUN wget -nv https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz && \
    tar xf zig-x86_64-linux-0.15.2.tar.xz && \
    mv zig-x86_64-linux-0.15.2 /usr/local/zig && \
    rm zig-x86_64-linux-0.15.2.tar.xz
ENV PATH="/usr/local/zig:$PATH"

WORKDIR /app
COPY . .

# Generate IVF index if not committed (~90s). Skip if index.bin already exists.
RUN if [ ! -f resources/index.bin ]; then \
      zig build-exe tools/build_index.zig -O ReleaseFast --name build_index_tool && \
      ./build_index_tool resources/references.json.gz resources/index.bin && \
      rm -f build_index_tool; \
    fi

# Build: static musl binary, AVX2+FMA (haswell = Mac Mini Intel target)
RUN zig build --release=fast -Dtarget=x86_64-linux-musl -Dcpu=haswell

FROM scratch
COPY --from=builder /app/zig-out/bin/api /api
EXPOSE 9999
ENTRYPOINT ["/api"]
