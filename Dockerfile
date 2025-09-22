ARG ERLANG_VERSION=28.0.2.0
ARG GLEAM_VERSION=v1.12.0
# Use the official Gleam image with Erlang
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-scratch AS gleam


FROM erlang:${ERLANG_VERSION}-alpine AS build
COPY --from=gleam /bin/gleam /bin/gleam
COPY . /app/
RUN cd /app && gleam export erlang-shipment

FROM erlang:${ERLANG_VERSION}-alpine

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
