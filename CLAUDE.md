# Working in this repo

## Communication

**Always use full absolute paths** when referring to files, in prose and in commands alike. `/home/user/src/helm-mirofish/charts/mirofish-offline/values.yaml`, not `values.yaml` or `charts/.../values.yaml`. In shell commands prefer `git -C "$PATH" ...` and `make -C "$PATH" ...` over `cd` followed by a bare command, so nothing depends on the working directory.

Paths *inside* the repo — the Makefile, workflows, chart templates — stay repo-relative, because a clone has to work from any location. The rule is about how paths are communicated, not how they are stored.

## Before proposing any change

```bash
make -C "$REPO" check
```

Runs `helm lint --strict`, renders every scenario in `$REPO/charts/mirofish-offline/ci/` against Kubernetes 1.27/1.29/1.31 with kubeconform, asserts the chart rejects values it cannot support, and sweeps object-name uniqueness and length across release-name lengths 1–53. This is exactly what CI runs; a green local run means a green PR.

If `$REPO/UPSTREAM_REF` changed, also run `make -C "$REPO" relock` then `make -C "$REPO" check-lock`.

## Things that look like bugs but are deliberate

- **`api.replicaCount` is capped at 1 and the render fails above it.** Simulation subprocesses and task progress live in the serving gunicorn process, and the uploads volume is ReadWriteOnce. A second replica would answer status queries about work it never started. Do not "fix" this by relaxing the check.
- **The model-pull Job is a plain Job, not a Helm hook.** A hook would make `helm install` block for the length of a multi-gigabyte download, breaking CI timeouts and GitOps reconciliation.
- **The Job never runs when `ollama.enabled` is false.** Pushing weights into a server the operator does not own is not an acceptable default.
- **`$REPO/docker/backend-uv.lock` overrides upstream's `backend/uv.lock`.** Upstream's is the pre-fork lock — it names the project `mirofish-backend 0.1.0`, still carries `zep-cloud`, and `uv sync` against it fails outright. Regenerate with `make -C "$REPO" relock`, never by copying upstream's back.
- **`OASIS_DEFAULT_MAX_ROUNDS` and the `REPORT_AGENT_*` variables are not exposed as values.** Upstream reads them into its `Config` class but nothing consumes them. Exposing them would be offering settings that quietly do nothing.

## Two traps already paid for

- **gunicorn must be installed *after* the last `uv sync`.** `uv sync` is exact by default and prunes anything absent from the lockfile, so installing earlier leaves the image without the binary its `CMD` invokes. `$REPO/docker/api.Dockerfile` has a build-time assertion for this.
- **`COPY --from=` cannot take a variable stage name.** BuildKit resolves stage names before build args. Pull versioned images in as a named `FROM ... AS` stage instead.

## Releases

Driven by semantic-release from conventional commits on `main`, like the rest of the estate. **Never edit `version:` in `$REPO/charts/mirofish-offline/Chart.yaml` by hand** — semantic-release owns it, and a manual edit is either overwritten or produces a version nothing else agrees with.

- `fix:` patch, `feat:` minor, `feat!:` or a `BREAKING CHANGE:` footer major. `chore:`/`docs:`/`ci:` release nothing.
- The `v<version>` tag semantic-release pushes is what builds the images. The chart of that version defaults its image tag to `.Chart.Version`, so the two are the same number by construction.
- `appVersion` is **not** touched (`onlyUpdateVersion` is set). It records which upstream MiroFish is inside and moves only when `UPSTREAM_REF` does — change both in the same commit.
- The release runs under `POL_GH_TOKEN`, not `GITHUB_TOKEN`. Pushes made with `GITHUB_TOKEN` do not trigger workflows, so the tag would land and the images would never build.
