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

> [!WARNING]
> **PR build cache and forks**
>
> The PR workflow uses a GHCR registry-backed BuildKit cache (e.g. `:buildcache-pr`). This requires authenticating to GHCR with the repo-scoped `GITHUB_TOKEN` and `packages: write` permissions.
>
> As a result, this setup will only work for pull requests from branches within this repository. For fork-based PRs, GitHub typically restricts token permissions, and the registry cache push/pull can fail (e.g. 403 from `ghcr.io/token`).
>
> If we need to support fork PRs we will need to disable registry caching in the PR workflow by removing `cache-from` / `cache-to` (or switching to a fork-safe cache strategy).


### 3) Multi-architecture builds (amd64 + arm64)

We publish a multi-arch image for:

* `linux/amd64`
* `linux/arm64`

This makes the same image tag usable on both x86 and ARM-based fleets.

In CI, Buildx can build non-native architectures using QEMU emulation. For production pipelines we should use native builders per architecture (or dedicated arm64 runners) for speed and to avoid emulation edge cases.

### 4) Build-time secrets (no leaking into layers)

BuildKit supports secret mounts so credentials (e.g., private npm registry tokens) are available only during a specific `RUN` step and are not persisted into image layers.

We do not use build-time secrets in this repo today, but the pattern is useful for enterprise builds.

## Docker Scanning (CI/CD gate with Trivy)

This repo uses **Trivy** to scan container images for security issues and to fail CI when the image contains fixable HIGH/CRITICAL vulnerabilities.

### What Trivy is scanning

When you scan an image, Trivy typically reports findings in separate sections, for example:
- **OS packages** (e.g., `debian 12.x`): vulnerabilities from distro packages present in the final filesystem (usually from the base image, or anything you installed with the OS package manager).
- **Language dependencies** (e.g., `Node.js (node-pkg)`): vulnerabilities from application dependency graphs (npm/yarn/pnpm etc) that exist in the image filesystem.

### Multi-arch scanning (amd64 + arm64)

This repo support both `linux/amd64` and `linux/arm64`. Since vulnerabilities can differ by architecture (different package builds/versions), we scan each platform in a matrix.

In `cd.yml`, the `scan` job sets the platform using a Trivy config file per matrix entry:

```yaml
- name: Write Trivy config for platform
  run: |
    cat > trivy.yaml <<'YAML'
    image:
      platform: "${{ matrix.platform }}"
    YAML
```

### “Fail the build” policy (fixable HIGH/CRITICAL only)

The gate is intentionally strict, but tries to be practical:

* `severity: CRITICAL,HIGH`
* `exit-code: "1"` (fail when findings exist)
* `ignore-unfixed: true` to avoid blocking releases on vulnerabilities that currently have no upstream fix

### VEX (suppressing non-exploitable findings)

To reduce false positives safely, Trivy can apply **VEX** (“Vulnerability Exploitability eXchange”) statements using `--vex`.

This repo supports a local OpenVEX file at the repo root:

* `vex.openvex.json`

If present, CI will pass it to Trivy to filter findings accordingly.

### GitHub Actions integration details

We use `aquasecurity/trivy-action` to run Trivy in GitHub Actions.

### Troubleshooting notes

* If a vulnerability appears in the **OS section**, start by scanning the base image directly to confirm whether it’s inherited.
* If a vulnerability appears in the **Node.js section**, check whether it’s in your app dependency graph vs bundled tooling in the base image (Trivy JSON output can help locate where it was discovered).

### Running locally + creating VEX exceptions

This repo supports a simple local workflow to:
1) scan an image with Trivy
2) generate (or update) an OpenVEX file to suppress specific CVEs
3) re-run the scan with VEX applied

> [!IMPORTANT]
> VEX should be used to document **non-exploitable** findings (with a justification), not to 
"hide" real risk. VEX is typically managed centrally by security.

### 1) Build the image locally

Build a local image (example tag):

```bash
docker build -t hello-express:local .
```

### 2) Run Trivy locally (create `trivy.json`)

Generate a JSON report so you can extract package PURLs (Package URL) precisely:

```bash
trivy image \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --format json \
  -o trivy.json \
  hello-express:local
```

### 3) Create/update an OpenVEX file for a CVE

Use `create_vex.sh` to generate/update `vex.openvex.json` from `trivy.json`.

Example:

```bash
./create_vex.sh CVE-2025-64756 \
  --image-repo "ghcr.io/OWNER/REPO" \
  --trivy-json trivy.json \
  --status not_affected \
  --justification vulnerable_code_not_in_execute_path \
  --comment "glob is not used by the application at runtime; present only via bundled tooling."
```

What this does:

* finds all package PURLs in `trivy.json` that match the CVE (e.g., `pkg:npm/glob@...`)
* writes/updates `vex.openvex.json`
* scopes the exception to your OCI image repo and the specific subcomponents (package PURLs)

### 4) Re-scan with VEX applied

Trivy can apply VEX during image scanning using `--vex`:

```bash
trivy image \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --vex vex.openvex.json \
  hello-express:local
```

If the VEX statement matches the vulnerable package PURL(s), Trivy will filter those findings accordingly.

### 5) Commit and push (lab workflow)

If you’re using repo-local VEX for this lab:

```bash
git add vex.openvex.json
git commit -m "vex: suppress CVE-2025-64756 (not exploitable)"
git push
```

CI will automatically detect `vex.openvex.json` and apply it during scans.
