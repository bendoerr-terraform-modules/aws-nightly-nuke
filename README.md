# aws-nightly-nuke

Automated AWS sandbox account cleanup using [ekristen/aws-nuke](https://github.com/ekristen/aws-nuke).

## What It Does

This repo runs [aws-nuke](https://github.com/ekristen/aws-nuke) on a schedule to delete all resources from the
`brd-sndbx` (sandbox) AWS account. It keeps the sandbox clean so leftover experiments, test infrastructure, and
forgotten resources don't pile up and cost money.

## Schedule

The workflow runs **every 6 hours** (00:00, 06:00, 12:00, 18:00 UTC) via cron. Scheduled runs execute
with `--no-dry-run` and actually delete resources. Pull requests trigger a dry-run only.

## Manual Runs

You can trigger a run manually via **Actions → AWS Nuke → Run workflow**:

- Set `delete` to `"false"` (default) for a dry-run
- Set `delete` to `"true"` to actually delete resources

## Target Account

| Field | Value |
|-------|-------|
| Account ID | `234656776442` |
| Alias | `brd-sndbx` |
| Region | `us-east-1` (+ `global`) |
| Auth | OIDC via `brd-sndbx-ue1-core-admins` role |

## Protected Resources

The following resources are **excluded** from deletion (see `sandbox-nuke.yml`):

- **IAM Users**: `brd-sndbx-ue1-core-apply`, `brd-sndbx-ue1-core-bendoerr`
- **IAM Roles**: `OrganizationAccountAccessRole`, `brd-sndbx-ue1-core-admins`, `brd-sndbx-ue1-core-apply`
- **IAM Group**: `brd-sndbx-ue1-core-admins` (and its policy attachments)
- **IAM Policies**: `brd-sndbx-ue1-core-apply-1`, `brd-sndbx-ue1-core-apply-2`
- **OIDC Provider**: GitHub Actions OIDC (`token.actions.githubusercontent.com`)
- **MFA Device**: `1Password` virtual MFA
- **IAM Access Keys**: Protected via secrets (key IDs stored as GitHub repo secrets)
- **IAM Login Profile & Group Attachments**: For the `bendoerr` user

## How to Add New Exclusions

1. Edit `sandbox-nuke.yml`
2. Add a filter entry under the appropriate resource type in `accounts."234656776442".filters`
3. The filter value format is the resource identifier as shown by aws-nuke output (e.g., `"resource-name"` or `"resource-name -> property"`)
4. Open a PR — the dry-run will confirm the resource is now excluded
5. Merge after review

## Resource Type Exclusions

The `OSPackage` resource type is globally excluded because it causes errors.

## Secrets

| Secret | Purpose |
|--------|---------|
| `SANDBOX_NUKE_KEY_ID_APPLY` | IAM access key ID for `brd-sndbx-ue1-core-apply` user |
| `SANDBOX_NUKE_KEY_ID_BENDOERR` | IAM access key ID for `brd-sndbx-ue1-core-bendoerr` user |
| `DISCORD_WEBHOOK` | Discord webhook for failure notifications |
