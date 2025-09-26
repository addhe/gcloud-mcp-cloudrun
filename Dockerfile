# Dockerfile for gcloud-mcp Cloud Run service
# Uses node:20-slim as base, installs production deps, and runs a small HTTP proxy

FROM gcr.io/google.com/cloudsdktool/cloud-sdk:slim

# Install Node.js 20 (Debian based)
RUN set -eux; \
		apt-get update; \
		apt-get install -y --no-install-recommends curl ca-certificates gnupg2 dirmngr build-essential; \
		curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; \
		apt-get install -y --no-install-recommends nodejs; \
		apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*;

# Create app directory
WORKDIR /usr/src/app

# Copy package and lockfile and install deps reproducibly
# This Dockerfile requires a committed package-lock.json for deterministic builds.
COPY package.json package-lock.json ./
RUN set -e; \
	if [ ! -f package-lock.json ]; then \
		echo "\nERROR: package-lock.json not found. For reproducible builds please commit package-lock.json (run 'npm install' locally then commit).\n"; \
		exit 1; \
	fi; \
	npm ci --omit=dev --no-audit --no-fund

# Copy server code
COPY server.js ./

# Expose port (Cloud Run uses 8080 by default)
EXPOSE 8080

# Start the server
CMD ["node", "server.js"]
