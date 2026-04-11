# AWS CI/CD Pipeline with Terraform and GitHub Actions

## Overview

This project implements a CI/CD pipeline that automatically plans and deploys AWS infrastructure using Terraform and GitHub Actions. It consists of a bootstrap layer that sets up OIDC-based authentication between GitHub and AWS, and an infrastructure layer that deploys an S3 static website. Every Pull Request triggers a `terraform plan` with a security scan, and every merge to `main` triggers a `terraform apply` — with no long-lived AWS credentials stored anywhere.

---

## Architecture Diagram

```
Developer pushes to feature branch
              ↓
      Opens Pull Request
              ↓
  GitHub Actions triggers plan workflow
    → terraform fmt -check
    → terraform validate
    → checkov security scan
    → terraform plan
    → plan posted as PR comment
              ↓
    Developer reviews plan output
              ↓
        Merges PR into main
              ↓
  GitHub Actions triggers apply workflow
    → terraform apply -auto-approve
              ↓
    Infrastructure deployed to AWS
```

---

## Project Structure

```
terraform-aws-cicd-pipeline/
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml      # triggers on Pull Request
│       └── terraform-apply.yml     # triggers on merge to main
├── bootstrap/                      # OIDC provider + IAM role — deployed once, manually
│   ├── main.tf
│   ├── outputs.tf
│   └── providers.tf
├── infra/                          # S3 static website — managed by the pipeline
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── providers.tf
└── README.md
```

---

## How It Works

### The Problem with Storing AWS Credentials in GitHub

The naive approach to giving GitHub Actions access to AWS is to create an IAM user, generate access keys, and store them as GitHub secrets. This has serious security drawbacks — the keys are long-lived, they never expire, and if they are ever leaked they give an attacker persistent access to your AWS account.

### The Solution: OIDC Federation

Instead of storing credentials, we use OpenID Connect (OIDC) federation. GitHub acts as an identity provider — when a workflow runs, GitHub generates a short-lived JWT token signed by GitHub's own certificate authority. AWS verifies this token against a registered OIDC provider and, if the token is valid and the conditions are met, returns temporary credentials that expire after the workflow finishes.

No credentials are stored anywhere. No credentials can be leaked. Every workflow run authenticates fresh.

---

## Bootstrap Layer

The bootstrap layer is deployed once, manually, from a local machine. It registers GitHub as a trusted identity provider in AWS and creates the IAM role that GitHub Actions will assume.

### `aws_iam_openid_connect_provider`

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
```

This resource registers GitHub's token service as a trusted identity provider inside your AWS account. Think of it as adding GitHub to AWS's approved list of ID issuers.

- `url` — the issuer URL of GitHub's OIDC token service. AWS uses this to know where to validate incoming tokens.
- `client_id_list` — the audience the token must be intended for. `sts.amazonaws.com` means the token must have been requested specifically for AWS STS (the service that issues temporary credentials).
- `thumbprint_list` — the TLS certificate fingerprint of GitHub's token service. AWS uses this to verify that tokens actually came from GitHub and not from someone impersonating GitHub.

### `data "aws_iam_policy_document"` — Assume Role Policy

```hcl
data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:YOUR_GITHUB_USERNAME/terraform-aws-cicd-pipeline:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
```

This data source builds the trust policy for the IAM role in native HCL rather than raw JSON. It is not a resource — it generates no infrastructure. It compiles to a valid IAM policy JSON string that is referenced by the IAM role via `.json`.

**`principals` block**

Defines who is allowed to attempt to assume this role. `type = "Federated"` means the principal is an external identity provider, not an AWS entity like an IAM user or service. `identifiers` points to the OIDC provider ARN registered above — only tokens validated by that specific provider are considered.

**Condition 1 — Lock to your repository**

The `sub` (subject) claim inside every GitHub JWT token identifies exactly where the workflow came from. For a push to main it looks like:

```
repo:leomarqueslimait-jpg/terraform-aws-cicd-pipeline:ref:refs/heads/main
```

The `StringLike` operator with a `*` wildcard at the end covers both push and pull_request events, which generate slightly different subject strings. Without this condition, any GitHub Actions workflow from any repository in the world could assume this role.

**Condition 2 — Verify token audience**

The `aud` (audience) claim specifies what service the token was intended for. GitHub sets this claim when the token is generated — the `aws-actions/configure-aws-credentials` action requests a token with `aud = sts.amazonaws.com` before sending it to AWS. This condition verifies that the token was indeed intended for AWS and not replayed from another platform.

Both conditions must pass simultaneously. If either fails, AWS rejects the request.

### `aws_iam_role`

```hcl
resource "aws_iam_role" "github_actions" {
  name               = "github-actions-terraform-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}
```

The IAM role that GitHub Actions assumes during each workflow run. The `.json` attribute at the end of the data source reference is how Terraform converts the HCL policy document into the JSON string that IAM expects.

### `aws_iam_role_policy_attachment`

```hcl
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
```

Attaches `AdministratorAccess` to the role so the pipeline can create any AWS resource. In a production environment this would be scoped down to only the permissions needed for the specific infrastructure being deployed.

---

## Infrastructure Layer

The `infra/` directory contains the Terraform code that the pipeline deploys — an S3 static website. The infrastructure itself is intentionally simple. The point of this project is the pipeline.

### `aws_s3_bucket`

The S3 bucket that hosts the static website files. S3 bucket names are globally unique across all AWS accounts.

### `aws_s3_bucket_public_access_block`

```hcl
resource "aws_s3_bucket_public_access_block" "static_site" {
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}
```

Since 2023 AWS enables a "block all public access" guardrail on every new S3 bucket by default. This resource explicitly disables those guardrails so the bucket can serve a public website. All four settings must be set to `false` — setting only some of them still blocks public access partially.

### `aws_s3_bucket_website_configuration`

```hcl
resource "aws_s3_bucket_website_configuration" "static_site" {
  index_document { suffix = "index.html" }
  error_document { key    = "error.html" }
}
```

Enables static website hosting on the bucket. Without this resource the bucket is just object storage. With it, AWS activates a website endpoint URL and serves files as HTTP responses. The `website_endpoint` exported attribute of this resource is used in the outputs to print the website URL after deployment.

### `aws_s3_bucket_policy` and `aws_iam_policy_document`

The bucket policy allows any principal (`"*"`) to perform `s3:GetObject` on any object in the bucket. This is what makes the website publicly readable. The `depends_on` on this resource ensures the public access block is disabled before the public policy is applied — AWS rejects a public bucket policy if the block is still active.

---

## GitHub Actions Workflows

Workflow files live in `.github/workflows/` and are YAML files that define automated processes triggered by GitHub events.

### Workflow Anatomy

```yaml
name: Terraform Plan        # display name shown on GitHub

on:                         # what event triggers this workflow
  pull_request:
    branches: [main]
    paths:
      - 'infra/**'          # only trigger if files in infra/ changed

permissions:                # what the workflow's GitHub token can do
  id-token: write           # required for OIDC — allows requesting a JWT token
  contents: read
  pull-requests: write      # allows posting comments on PRs

jobs:
  plan:
    runs-on: ubuntu-latest  # GitHub spins up a fresh Ubuntu VM for each run

    defaults:
      run:
        working-directory: infra  # all run steps execute from infra/ by default

    steps:                  # sequential steps inside the job
      - name: step name
        uses: some/action   # a pre-built action from the GitHub Marketplace
        run: some command   # a raw shell command on the Ubuntu VM
```

### Key Workflow Concepts

**`on.branches` vs `on.paths`** — These two filters are independent and both must pass for the workflow to trigger.

`branches: [main]` filters by the **target** of the PR — the branch you are trying to merge into. It does not care what your feature branch is called. It only asks: *"Is this PR targeting main?"* A PR targeting a `staging` or `dev` branch would be ignored.

`paths: - 'infra/**'` filters by **which files changed** in the PR, regardless of branches. It asks: *"Did any files inside `infra/` change?"* A PR that only touches the README or the bootstrap folder will not trigger the workflow even if it targets main.

Both conditions must be true simultaneously:

```
PR targets main          AND     files in infra/ changed
       ↓                                  ↓
  branches filter                    paths filter
       ↓                                  ↓
              both true → workflow triggers
              either false → workflow skipped
```

This matters in practice — if you update your README and open a PR to main, Terraform should not run a plan on infrastructure that did not change. The `paths` filter prevents that noise.

**`on.paths`** — Only triggers the workflow if files matching the pattern changed. A change to only the README will not trigger a Terraform plan. This avoids unnecessary pipeline runs.

**`permissions.id-token: write`** — This is the critical permission for OIDC. Without it, the workflow cannot request a JWT token from GitHub to send to AWS. The workflow would fail at the credentials step.

**`runs-on: ubuntu-latest`** — GitHub spins up a completely fresh Ubuntu virtual machine for every workflow run. Nothing persists between runs. Every tool must be installed fresh each time, which is what the `uses` steps do.

**`defaults.run.working-directory`** — Sets `infra/` as the default directory for all `run` steps so every command executes from there without needing explicit `cd infra` in every step.

**`uses` vs `run`** — `uses` runs a pre-built action from the GitHub Marketplace (someone else's code, like installing Terraform or configuring AWS credentials). `run` executes a raw shell command directly on the Ubuntu VM, exactly like typing in a terminal.

### `actions/checkout@v4`

Checks out your repository code onto the GitHub VM. Without this step the VM has no idea what your files look like — it is a blank Ubuntu machine.

### `hashicorp/setup-terraform@v3`

Downloads and installs Terraform on the Ubuntu VM. Without this step, `terraform` would not be a recognized command.

### `aws-actions/configure-aws-credentials@v4`

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
    aws-region: us-east-1
    audience: sts.amazonaws.com
```

This action handles the entire OIDC authentication flow:
1. Requests a JWT token from GitHub with `aud = sts.amazonaws.com`
2. Sends the token to AWS STS along with the role ARN
3. AWS validates the token against the OIDC provider and conditions
4. AWS returns temporary credentials
5. The action sets those credentials as environment variables for the rest of the workflow

The `audience` attribute must match the `client_id_list` in the OIDC provider and the `aud` condition in the trust policy. `${{ secrets.AWS_ROLE_ARN }}` references the GitHub secret added manually after the bootstrap deployment.

### Terraform Steps

**`terraform fmt -check -recursive`** — Checks that all Terraform files are correctly formatted without modifying them. Fails the pipeline if formatting is wrong, enforcing consistent code style.

**`terraform validate`** — Validates the Terraform configuration for syntax errors and internal consistency. Does not connect to AWS — purely a local check.

**`terraform plan -no-color 2>&1 | tee plan_output.txt`** — Runs the plan and saves the output to a file using `tee`. The `2>&1` redirects error output alongside normal output so both are captured. `-no-color` strips terminal color codes so the output renders cleanly as text in the PR comment.

**`terraform apply -auto-approve`** — Applies the plan without prompting for confirmation. The `-auto-approve` flag is required in a pipeline because there is no human at a terminal to type `yes`.

### Posting the Plan to the PR

```bash
PLAN=$(cat plan_output.txt)
gh pr comment ${{ github.event.pull_request.number }} \
  --body "### Terraform Plan 📖
\`\`\`
${PLAN}
\`\`\`"
```

`gh` is the GitHub CLI, pre-installed on GitHub's Ubuntu runners. `PLAN=$(cat plan_output.txt)` reads the saved plan file into a bash variable. The `gh pr comment` command posts it as a markdown-formatted comment on the PR. `GITHUB_TOKEN` is a secret GitHub automatically injects into every workflow run — no setup required.

---

## Checkov Security Scanning

```yaml
- name: Install Checkov
  run: pip install checkov

- name: Run Checkov
  run: |
    checkov -d . \
      --soft-fail \
      --output cli \
      --quiet
```

Checkov is a static analysis tool that scans Terraform files for security misconfigurations before anything is deployed. It reads `.tf` files and checks them against a library of security rules without connecting to AWS.

**`--soft-fail`** — Prints findings but does not fail the pipeline. Used here because the S3 public access findings are intentional for a static website.

**`--quiet`** — Prints only failed checks, keeping the log output clean.

For findings that are intentional, Checkov skip comments are added inline to explicitly document the conscious decision:

```hcl
#checkov:skip=CKV_AWS_21: Versioning not needed for static website
```

This is more valuable than simply suppressing all warnings — it proves awareness of each finding and a deliberate choice to accept it.

---

## Skills Learned

### OIDC Federation

The most important concept in this project. Understanding how short-lived JWT tokens replace long-lived credentials, how AWS validates tokens against a registered identity provider, and how trust policy conditions lock role assumption to a specific repository is knowledge directly applicable to any role using AWS with a CI/CD system.

### GitHub Actions

Defining automated workflows triggered by repository events. Understanding the difference between `uses` and `run`, how permissions control what the workflow token can do, and how tools like Terraform and the AWS CLI are made available on a fresh Ubuntu runner.

### Terraform in a Pipeline

Running Terraform non-interactively with `-auto-approve`, using `-no-color` for clean log output, capturing plan output with `tee`, and separating plan and apply into distinct workflow triggers that mirror the pull request review process.

### Security Scanning with Checkov

Integrating static analysis into a pipeline and understanding the difference between suppressing warnings blindly and explicitly acknowledging accepted risks with documented justification.

### Git Branching and Pull Requests

Working on feature branches, opening pull requests, and using the merge event as the deployment trigger — the standard workflow in every professional engineering team.

---

## Biggest Challenge

The OIDC trust policy conditions. The `sub` claim format must match exactly what GitHub sends — including not having the full GitHub URL, just the `repo:username/reponame:*` pattern. The `aud` claim must also be `sts.amazonaws.com` (not `sts.amazon.com`). A single character difference in either condition causes AWS to silently reject the token with a generic `Incorrect token audience` or `Not authorized` error that gives no indication of which condition failed.

---

## Intended Audience

This project is intended to demonstrate CI/CD and DevSecOps capabilities for roles such as Cloud Engineer, DevOps Engineer, or Platform Engineer. It shows the ability to automate infrastructure deployment, implement credential-free authentication using modern identity federation, integrate security tooling into a pipeline, and mirror professional team workflows using Git branching and pull requests.

---

## Design Decisions

### Why OIDC instead of IAM user access keys

Access keys are long-lived and never expire unless manually rotated. If leaked through a public repository, a misconfigured application, or a compromised developer machine they give persistent AWS access. OIDC tokens expire after the workflow finishes — typically minutes. There is nothing to leak and nothing to rotate.

### Why separate plan and apply workflows

Separating plan and apply into distinct triggers mirrors how real teams work — changes are reviewed before they are deployed. The plan workflow gives a human the opportunity to see exactly what Terraform intends to do before it does it. Merging the PR is the explicit approval signal.

### Why `--soft-fail` on Checkov

Removing all Checkov findings by fixing them would require adding logging, versioning, encryption, and replication to a demo static website — adding significant complexity with no educational value. Using `--soft-fail` with explicit skip comments demonstrates awareness of every finding and a conscious, documented decision to accept each one.

---

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.5.0
- A GitHub account and repository
- An S3 bucket and DynamoDB table for remote state

---

## Deployment

### 1. Bootstrap (run once, manually)

```bash
cd bootstrap
terraform init
terraform apply
```

Copy the `github_actions_role_arn` output and add it as a GitHub secret named `AWS_ROLE_ARN`.

Also add a second secret named `BUCKET_NAME` with the name of your static site S3 bucket.

### 2. Let the pipeline handle everything else

```bash
git checkout -b feature/your-change
# make your changes
git add .
git commit -m "your message"
git push origin feature/your-change
```

Open a Pull Request on GitHub. The plan workflow runs automatically. Review the plan output in the PR comment. Merge the PR. The apply workflow runs automatically.

---

## Cost Estimate

| Resource | Cost |
|---|---|
| S3 bucket (static site) | ~$0.00 for minimal traffic |
| S3 bucket (remote state) | ~$0.00 for minimal storage |
| GitHub Actions | Free for public repositories |
| IAM / OIDC provider | No cost |
| **Total** | **~$0.00** |

---

## Destroy

```bash
cd infra
terraform destroy \
  -var="bucket_name=YOUR_BUCKET_NAME" \
  -var="environment=dev"

cd ../bootstrap
terraform destroy
```

Note: the S3 bucket must be emptied before Terraform can destroy it. Empty it first via the AWS Console or CLI:

```bash
aws s3 rm s3://YOUR_BUCKET_NAME --recursive
```
