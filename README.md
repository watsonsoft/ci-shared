# ci-shared

Shared CI for watsonsoft: the runner picker and the runner pool's self-test.

## Runner picker

One reusable workflow, [`runner-picker.yml`](.github/workflows/runner-picker.yml), chooses where every repo's CI jobs run. Pin it by tag:

```yaml
jobs:
  pick:
    uses: watsonsoft/ci-shared/.github/workflows/runner-picker.yml@v1   # moves to each v1.x.y; pin v1.1.0 to stay put
    secrets: inherit            # RUNNER_STATUS_TOKEN, set in each repo by the owner's token script
    # with:
    #   deploy: true                         # a deploy-only workflow: always the fallback
    #   force: fallback                      # pool | fallback, to validate one path

  test:
    needs: pick
    runs-on: ${{ fromJSON(needs.pick.outputs.runner) }}

  deploy:                       # deploy jobs never run on the pool
    needs: pick
    runs-on: ${{ fromJSON(needs.pick.outputs.fallback) }}
```

Outputs: `runner` and `fallback` (JSON for `fromJSON`), `pool` (`'true'` when the jobs go to the pool) and `reason`. The picker writes its choice and the reason to its job summary.

**The rule** ([`picker/decide.sh`](picker/decide.sh)):

1. A pull request from a fork, or a deploy, goes to the fallback.
2. Otherwise, if any pool runner (label `home-wsl`) is online, the pool. If every pool runner is busy the job waits for one, unless overflow mode is on: then the fallback.
3. With the pool offline, or its status unreadable (no token, an API error), the fallback.

The fallback is `ubuntu-latest` for a public repo and Ubicloud for a private one. The picker's own job runs on `ubuntu-latest` or `ubicloud-standard-2`, never the pool.

**The Ubicloud size** is set centrally like overflow mode: `fallback_size` in [`settings.json`](settings.json) on `main`, which the owner sets with `ci-fallback-size <label>`. A repo variable `CI_FALLBACK_SIZE` overrides it for one repo (`ci-fallback-size <label> --repo NAME`). With neither, it's `ubicloud-standard-2`. A value that isn't a Ubicloud label gives `ubicloud-standard-2`, and the job summary says why. Jobs that must stay off the pool (deploys, Supabase jobs) use the `fallback` output, so they follow the size too. The `fallback-size` input was retired in v1.1.0: it's still accepted, ignored, and flagged in the summary.

**Versions:** `v1` moves to each backward-compatible release (`v1.0.0`, `v1.1.0`, ...) once its tests and the sample caller are green on `main`. A breaking change is `v2`.

**Overflow mode** is [`settings.json`](settings.json) on `main`, read at every run whatever tag a repo pins. The owner flips it with `ci-overflow on|off`. A repo variable `CI_OVERFLOW` (`on`/`off`) overrides it for one repo. Unreadable counts as off.

**Tests**: `picker/tests/test-decide.sh` runs the decision against saved runner-list responses in `picker/tests/responses/`. [`sample-caller.yml`](.github/workflows/sample-caller.yml) runs the picker for real on every push and pull request.
