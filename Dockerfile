# Use the official Gleam image with Erlang
FROM ghcr.io/gleam-lang/gleam:v1.12.0-erlang-alpine

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apk add --no-cache git

# Create necessary directories for pack (Linux data_local_dir pattern)
RUN mkdir -p /app/.local/share /app/.cache /tmp /data
RUN chmod 755 /app/.local/share /app/.cache /tmp /data
RUN chown -R gleam:gleam /data || chown -R 1000:1000 /data || true

# Copy gleam.toml and manifest first for better caching
COPY gleam.toml ./
COPY manifest.toml ./

# Download dependencies
RUN gleam deps download

# Copy source code
COPY src/ ./src/
COPY test/ ./test/

# Build the application
RUN gleam build

# Expose the port the app runs on
EXPOSE 3000

# Set environment variables
ENV PORT=3000
ENV HOME=/app

# Run the application
CMD ["gleam", "run"]