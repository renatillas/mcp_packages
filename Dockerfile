# Use the official Gleam image with Erlang
FROM ghcr.io/gleam-lang/gleam:v1.12.0-erlang-alpine AS build


# Set working directory and copy source
WORKDIR /app
COPY . .

# Force cache bust with timestamp and clean rebuild
RUN date > /tmp/build_time && rm -rf build && gleam export erlang-shipment

FROM erlang:27.1.1.0-alpine 

COPY --from=build /app/build/erlang-shipment /app
# Install system dependencies first
RUN apk add --no-cache git

RUN mkdir -p /app/.local/share /app/.cache /tmp /data /app/docs_cache
RUN chmod 755 /app/.local/share /app/.cache /tmp /data /app/docs_cache
RUN chown -R gleam:gleam /data || chown -R 1000:1000 /data || true
EXPOSE 3000
ENV PORT=3000
ENV HOME=/app
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
