# ---- BUILD STAGE ----
# Use an official Node.js base image with Debian slim userspace.
# "slim" is smaller than full Debian, but still has enough tooling for builds.
FROM node:22-slim AS build

# Set the working directory for all subsequent commands in this stage.
# Creates /app if it doesn't exist.
WORKDIR /app

# Enable Corepack, which ships with Node and manages package managers (pnpm/yarn).
# This helps ensure the pnpm version is controlled via package.json "packageManager" (if set).
RUN corepack enable

# ---- PNPM SETUP (CACHE-FRIENDLY) ----
# Configure pnpm so its global home is outside /app.
# Keeping caches outside the workdir avoids accidental invalidation and keeps layers cleaner.
ENV PNPM_HOME=/pnpm

# Add PNPM_HOME to PATH so `pnpm` is available in RUN commands.
ENV PATH=$PNPM_HOME:$PATH

# Set pnpm's content-addressed store location.
# We point it to /pnpm/store so we can mount a BuildKit cache there during installs.
RUN pnpm config set store-dir /pnpm/store

# ---- DEPENDENCY INSTALL (CACHE OPTIMISED + DETERMINISTIC) ----
# Copy only the dependency manifests first.
# This is critical for fast rebuilds: changing source code later won't invalidate the dependency install layer.
COPY package.json pnpm-lock.yaml ./

# Use a BuildKit cache mount for the pnpm store:
# - speeds up repeated installs by reusing downloaded package artefacts
# - does NOT bake the cache into the image layers (so the final image stays small/clean)
# `--frozen-lockfile` enforces reproducibility: install must exactly match pnpm-lock.yaml.
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile


# ---- APP BUILD ----
# Copy build configuration separately (small change surface; keeps caching effective).
COPY tsconfig.json ./

# Copy application source last so code changes only invalidate the layers after this point.
COPY src ./src

# Compile/transpile your TypeScript (or build step) into /app/dist.
RUN pnpm run build

# Remove devDependencies after building, leaving only production deps in node_modules.
# This reduces size and attack surface for the runtime stage.
RUN pnpm prune --prod

# ---- RUNTIME STAGE ----
# Distroless Node image:
# - minimal userspace (no shell/package manager)
# - reduced attack surface + fewer CVEs
# - "nonroot" runs as an unprivileged user by default
FROM gcr.io/distroless/nodejs22-debian12:nonroot AS runtime

# Set runtime working directory.
WORKDIR /app

# Ensure frameworks/libraries run in production mode (often disables debug/dev behaviour).
ENV NODE_ENV=production

# Default port the app listens on (non-privileged port, good for non-root).
ENV PORT=8080

# Copy only what is required to run:
# - production-only node_modules (already pruned in build stage)
# - built output in dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist

# Start the service. Distroless Node images expect a JS entrypoint path.
# No shell form here (good): exec-form preserves signals properly.
CMD ["dist/index.js"]
