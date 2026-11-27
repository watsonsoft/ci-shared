# ci-shared

Shared CI for watsonsoft: the runner picker and the runner pool's self-test.

## Runner picker

One reusable workflow, [`runner-picker.yml`](.github/workflows/runner-picker.yml), chooses where every repo's CI jobs run. Pin it by tag:

```yaml
jobs:
  pick:
    uses: watsonsoft/ci-shared/.github/workflows/runner-picker.yml@v1
    secrets: inherit            # RUNNER_STATUS_TOKEN, set in each repo by the owner's token script
    # with:
    #   fallback-size: ubicloud-standard-4   # a private repo's fallback (default ubicloud-standard-2)
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

The fallback is `ubuntu-latest` for a public repo and `ubicloud-standard-2` (or `fallback-size`) for a private one. The picker's own job runs on the same kind of runner, never the pool.

**Overflow mode** is [`settings.json`](settings.json) on `main`, read at every run whatever tag a repo pins. The owner flips it with `ci-overflow on|off`. A repo variable `CI_OVERFLOW` (`on`/`off`) overrides it for one repo. Unreadable counts as off.

**Tests**: `picker/tests/test-decide.sh` runs the decision against saved runner-list responses in `picker/tests/responses/`. [`sample-caller.yml`](.github/workflows/sample-caller.yml) runs the picker for real on every push and pull request.
