# secure-docker-images

## Buildx (BuildKit)

This repository builds container images using Docker Buildx, which is the Docker CLI interface to the BuildKit build engine.

BuildKit/Buildx good practice because it improves build performance, enables multi-architecture images, and supports secure build-time secrets.

### 1) Cross-runner caching (registry-backed)

Github runners are often ephemeral, so local layer cache is unreliable. We export/import BuildKit cache to GHCR so builds can reuse work from previous runs (even on different runners):

```yaml
cache-from: type=registry,ref=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:buildcache-pr
cache-to: type=registry,ref=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:buildcache-pr,mode=max
````

We use separate caches:

* `:buildcache-pr` for pull requests
* `:buildcache` for main/release

This prevents PR builds from "polluting" the production cache while still keeping PR feedback fast.

### 2) Dependency download caching (pnpm store)

Even when a Docker layer cache is invalidated (for example, when `pnpm-lock.yaml` changes), BuildKit cache mounts can keep dependency downloads fast by persisting the pnpm store in the builder cache:

```dockerfile
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile
```

This does not end up in the final image, it only speeds up the build step. Combined with registry cache export, this cache can remain effective across CI runs.

### 3) Multi-architecture builds (amd64 + arm64)

We publish a multi-arch image for:

* `linux/amd64`
* `linux/arm64`

This makes the same image tag usable on both x86 and ARM-based fleets.

In CI, Buildx can build non-native architectures using QEMU emulation. For production pipelines we should use native builders per architecture (or dedicated arm64 runners) for speed and to avoid emulation edge cases.

### 4) Build-time secrets (no leaking into layers)

BuildKit supports secret mounts so credentials (e.g., private npm registry tokens) are available only during a specific `RUN` step and are not persisted into image layers.

We do not use build-time secrets in this repo today, but the pattern is useful for enterprise builds.

