# action-go-build-cache

A GitHub Action that restores and saves Go's build cache (`GOCACHE`) using an S3 bucket. Designed for use across multiple provider repositories that share the same bucket — each provider is isolated by a key prefix.

Save runs **automatically as a post-step** at the end of the job. No separate save step needed.

## How It Works

```mermaid
flowchart TD
    A([Job starts]) --> B[index.js\nmain phase]
    B --> C[restore.sh\ngo env GOCACHE]

    C --> D{Exact key\nin S3?}

    D -->|Hit| E[Download + extract\ncache-hit=true]
    D -->|Miss| F{Tier 1 prefix\nsame branch?}

    F -->|Hit| G[Download latest\ncache-hit=false]
    F -->|Miss| H{Tier 2 prefix\nany branch?}

    H -->|Hit| I[Download latest\ncache-hit=false]
    H -->|Miss| J[Cold miss\nno extraction]

    E --> K([Build runs])
    G --> K
    I --> K
    J --> K

    K --> L([Job ends])
    L --> M[index.js\npost phase]
    M --> N[save.sh\ngo env GOCACHE]
    N --> O{GOCACHE\nexists?}
    O -->|No| P([Skip — nothing to save])
    O -->|Yes| Q[tar + zstd compress]
    Q --> R[aws s3 cp upload\nprovider/key.tar.zst]
    R --> S[Cleanup temp file]
    S --> T([Done])
```

**On restore (job start):**
1. Resolves `GOCACHE` path via `go env GOCACHE`
2. Tries the exact key in S3 → downloads and extracts if found (`cache-hit=true`)
3. Falls back through `restore-keys` prefixes, picking the most recently modified object for each → downloads and extracts on first match (`cache-hit=false`)
4. Cold miss if nothing found — build proceeds from scratch

**On save (job end, automatic):**
1. Compresses `GOCACHE` with `tar` + `zstd`
2. Uploads the archive to S3 under `<provider>/<key>.tar.zst`
3. Cleans up the local temp archive

## S3 Key Structure

All providers share a single bucket, separated by prefix:

```
<bucket>/
  aws/Linux-go-build-release-v2.5-abc123.tar.zst
  azure/Linux-go-build-release-v1.3-def456.tar.zst
  gcp/Linux-go-build-main-ghi789.tar.zst
```

### Restore fallback chain

```
1. <provider>/Linux-go-build-<branch>-<go.sum hash>   exact match
       ↓ miss
2. <provider>/Linux-go-build-<branch>-*               latest on same branch
       ↓ miss
3. <provider>/Linux-go-build-*                        latest in provider, any branch
       ↓ miss
   cold build
```

Tier 2 gives the best partial reuse when `go.sum` changes slightly between commits on the same branch. Tier 3 covers first builds on a new branch.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `provider` | yes | — | Short provider name used as S3 key prefix (e.g. `aws`, `azure`, `gcp`) |
| `key` | yes | — | Exact cache key. See recommended format below. |
| `restore-keys` | no | `''` | Newline-separated list of key prefixes for fallback restore, tried in order |
| `bucket` | yes | — | S3 bucket name |
| `aws-region` | no | `us-east-1` | AWS region where the bucket lives |

### Recommended key format

```yaml
key: ${{ runner.os }}-go-build-${{ env.SAFE_BRANCH }}-${{ hashFiles('**/go.sum') }}
restore-keys: |
  ${{ runner.os }}-go-build-${{ env.SAFE_BRANCH }}-
  ${{ runner.os }}-go-build-
```

Branch names must be sanitized before use — replace `/` with `-`:

```yaml
- name: Sanitize branch name
  run: echo "SAFE_BRANCH=$(echo '${{ github.ref_name }}' | tr '/' '-')" >> $GITHUB_ENV
```

## Outputs

| Output | Description |
|---|---|
| `cache-hit` | `true` if the exact key matched, `false` for fallback hits and cold misses |

## Authentication

The action uses the AWS CLI which reads credentials from the standard AWS credential chain. Authentication is configured by the caller — the action itself has no auth inputs.

### Recommended: GitHub OIDC → IAM Role

No long-lived credentials. The runner requests a short-lived JWT from GitHub's OIDC provider and exchanges it for temporary AWS credentials via `sts:AssumeRoleWithWebIdentity`.

#### 1. Create an IAM OIDC provider (one-time, per AWS account)

In the AWS Console or via CLI:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

#### 2. Create an IAM role

Create a role with this trust policy, scoped to all repos under the `upbound` org:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:upbound/*:*"
        }
      }
    }
  ]
}
```

Attach an inline policy granting S3 access to the cache bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::<bucket-name>",
        "arn:aws:s3:::<bucket-name>/*"
      ]
    }
  ]
}
```

#### 3. Add repository variables

In each repo that uses this action (or at the org level):

| Variable | Example value |
|---|---|
| `GO_BUILD_CACHE_BUCKET` | `upbound-go-build-cache` |
| `GO_BUILD_CACHE_AWS_REGION` | `us-east-1` |
| `GO_BUILD_CACHE_ROLE_ARN` | `arn:aws:iam::123456789012:role/go-build-cache` |

#### 4. Add `id-token: write` permission to your job

```yaml
permissions:
  id-token: write
  contents: read
```

#### 5. Add `configure-aws-credentials` before this action

```yaml
- uses: aws-actions/configure-aws-credentials@v6.1.0
  with:
    role-to-assume: ${{ vars.GO_BUILD_CACHE_ROLE_ARN }}
    aws-region: ${{ vars.GO_BUILD_CACHE_AWS_REGION }}
```

---

## Example: Provider repo usage

Below is a minimal example of how a provider repository (e.g. `provider-upjet-aws`) would integrate this action into its CI workflow.

```yaml
name: CI

on:
  push:
    branches:
      - main
      - release-*
  pull_request: {}

jobs:
  build:
    runs-on: ubuntu-24.04
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod

      - name: Configure AWS Credentials for Go build cache
        uses: aws-actions/configure-aws-credentials@v6.1.0
        with:
          role-to-assume: ${{ vars.GO_BUILD_CACHE_ROLE_ARN }}
          aws-region: ${{ vars.GO_BUILD_CACHE_AWS_REGION }}

      - name: Sanitize branch name
        run: echo "SAFE_BRANCH=$(echo '${{ github.ref_name }}' | tr '/' '-')" >> $GITHUB_ENV

      - name: Restore Go Build Cache
        uses: upbound/action-go-build-cache@main
        with:
          provider: aws
          key: ${{ runner.os }}-go-build-${{ env.SAFE_BRANCH }}-${{ hashFiles('**/go.sum') }}
          restore-keys: |
            ${{ runner.os }}-go-build-${{ env.SAFE_BRANCH }}-
            ${{ runner.os }}-go-build-
          bucket: ${{ vars.GO_BUILD_CACHE_BUCKET }}
          aws-region: ${{ vars.GO_BUILD_CACHE_AWS_REGION }}

      - name: Build
        run: make build

      # No save step needed — cache is saved automatically at job end.
```

### Notes

- The `provider` input is hardcoded per repo (`aws`, `azure`, `gcp`, etc.) — it determines the S3 key prefix
- The save step runs automatically via the action's post-step (`post-if: always()`), even if the build fails
- A partial cache from a failed build is still useful — Go reuses any unchanged artifacts on the next run
- `GOMODCACHE` is intentionally not cached — vendor mode (`go mod vendor`) makes it unused during build

## S3 Bucket Lifecycle Policy

Add a lifecycle rule to the bucket to automatically delete objects older than 90 days:

```json
{
  "Rules": [
    {
      "ID": "expire-go-build-cache",
      "Status": "Enabled",
      "Filter": { "Prefix": "" },
      "Expiration": { "Days": 90 }
    }
  ]
}
```

This covers all release cycles without manual cleanup.
