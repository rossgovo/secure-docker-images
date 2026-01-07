FROM node:22-slim AS build
WORKDIR /app
RUN corepack enable

# Configure pnpm store (outside the workdir)
ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN pnpm config set store-dir /pnpm/store

COPY package.json pnpm-lock.yaml ./

# Cache mount: speeds up repeated installs across builds
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile

COPY tsconfig.json ./
COPY src ./src
RUN pnpm run build
RUN pnpm prune --prod

FROM gcr.io/distroless/nodejs22-debian12:nonroot AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=8080

COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist

CMD ["dist/index.js"]
