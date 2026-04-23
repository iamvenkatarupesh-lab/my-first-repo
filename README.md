# Static Site on AWS ECS Fargate, Deployed by GitHub Actions

This is a complete, beginner-friendly setup. You'll end up with:

- A static HTML site running in a Docker container (nginx).
- Hosted on AWS ECS Fargate (the "serverless" way to run containers).
- Deployed automatically every time you push to `main` on GitHub.
- A single script / workflow to delete everything when you're done.

**Estimated cost if left running:** ~$10–15/month. **Delete it when you're done testing.**

---

## Files in this project

```
ecs-static-site/
├── site/index.html            # the page you're serving
├── Dockerfile                 # wraps site/ in an nginx container
├── task-definition.json       # template ECS uses to run your container
├── scripts/
│   ├── bootstrap.sh           # run ONCE to create all AWS resources
│   └── teardown.sh            # run to DELETE all AWS resources
└── .github/workflows/
    ├── deploy.yml             # auto-runs on push to main
    └── destroy.yml            # manual trigger to tear everything down
```

---

## Part 1 — One-time setup (do this once, on your laptop)

### Step 1. Create an AWS account

1. Go to <https://aws.amazon.com/> → **Create an AWS Account**.
2. You'll need a credit card, a phone number, and an email.
3. Choose the **Basic Support — Free** plan at the end.
4. Sign in to the AWS Console.

### Step 2. Create an IAM user for yourself (so you don't use the root account)

The root account you just signed up with is too powerful to use day-to-day.

1. In the AWS Console, search **IAM** → open it.
2. Left sidebar → **Users** → **Create user**.
3. Name it `admin-me`. Check **Provide user access to the AWS Management Console**.
4. Choose **I want to create an IAM user**. Set a password.
5. On Permissions → **Attach policies directly** → check **AdministratorAccess** → Next → Create.
6. Sign out, sign back in as `admin-me` (AWS will show you the sign-in URL).

### Step 3. Install the AWS CLI on your laptop

- **macOS**: `brew install awscli` (or download installer from AWS docs)
- **Windows**: download the MSI installer from the AWS CLI docs page
- **Linux**: `sudo apt-get install awscli` or follow AWS's install guide

Verify:
```bash
aws --version
```

### Step 4. Create access keys for the CLI

1. IAM → Users → click `admin-me` → **Security credentials** tab.
2. **Access keys** → **Create access key** → choose **Command Line Interface (CLI)**.
3. Save the **Access key ID** and **Secret access key**. You won't see the secret again.

Configure the CLI:
```bash
aws configure
# AWS Access Key ID:      (paste)
# AWS Secret Access Key:  (paste)
# Default region:         us-east-1
# Default output format:  json
```

Confirm it works:
```bash
aws sts get-caller-identity
```

### Step 5. Create a SEPARATE IAM user for GitHub Actions

You don't want GitHub to have your admin keys. Make a limited one.

1. IAM → Users → **Create user** → name it `github-actions-deployer`. **Do NOT** check console access.
2. Permissions → **Attach policies directly** → check:
   - `AmazonEC2ContainerRegistryPowerUser`
   - `AmazonECS_FullAccess`
   - `CloudWatchLogsFullAccess`
   - `IAMReadOnlyAccess` (needed to look up the execution role ARN)
3. Create user. Click into it → **Security credentials** → **Create access key** → choose **Third-party service** → save the Access key ID and Secret.

Keep these two values open in a tab — you'll paste them into GitHub in Part 3.

### Step 6. Run the bootstrap script (creates AWS resources)

From your laptop, in this project folder:

```bash
cd ecs-static-site
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

At the end it prints a list of values. Keep this terminal open.

---

## Part 2 — Push the code to your GitHub repo

You said you already have a repo. From this folder:

```bash
git init
git add .
git commit -m "Initial ECS setup"
git branch -M main
git remote add origin <YOUR_REPO_URL>
git push -u origin main
```

(Skip `git init` / `git remote add` if you're putting these files into an existing repo.)

---

## Part 3 — Tell GitHub the AWS secrets

In your GitHub repo:

**Settings → Secrets and variables → Actions → New repository secret**

Add all of these (values come from Step 5 and the bootstrap output):

| Secret name            | Value |
|------------------------|-------|
| `AWS_ACCESS_KEY_ID`    | from Step 5 (GitHub Actions user) |
| `AWS_SECRET_ACCESS_KEY`| from Step 5 |
| `AWS_REGION`           | `us-east-1` (or whatever you used) |
| `ECR_REPOSITORY`       | `static-site` |
| `ECS_CLUSTER`          | `static-site-cluster` |
| `ECS_SERVICE`          | `static-site-service` |
| `EXECUTION_ROLE_ARN`   | from bootstrap output (starts with `arn:aws:iam::...`) |

---

## Part 4 — Deploy

Push any change to `main`. Example:

```bash
# edit site/index.html
git add site/index.html
git commit -m "update homepage"
git push
```

In GitHub → **Actions** tab → watch **Deploy to ECS** run. At the end it prints a line like:

```
Site is live at: http://54.xxx.xxx.xxx
```

Open that IP in your browser. Done.

> Note: the public IP changes each time the task restarts. For a stable URL you'd add an Application Load Balancer + a domain — but that costs more and isn't part of this cheap setup.

---

## Part 5 — Delete everything when you're done

Two options. Pick one.

### Option A — From GitHub (easiest)

Go to **Actions → Destroy ECS stack → Run workflow**, type `DESTROY` in the confirm field, run it.

### Option B — From your laptop

```bash
chmod +x scripts/teardown.sh
./scripts/teardown.sh
```

Then in the AWS Console, double-check:

- **ECS → Clusters**: empty
- **ECR → Repositories**: empty
- **CloudWatch → Log groups**: no `/ecs/static-site`
- **EC2 → Security Groups**: no `static-site-sg`

If you're completely done with AWS, also delete the two IAM users (`admin-me` and `github-actions-deployer`) from IAM → Users.

---

## Troubleshooting

**"Service already exists" during bootstrap** — Harmless. The script is idempotent.

**Deploy succeeds but site doesn't load** — The security group might not allow port 80. In EC2 → Security Groups → `static-site-sg` → Inbound rules, confirm there's an entry for TCP 80 from `0.0.0.0/0`.

**Can't delete security group during teardown** — ECS takes 1–2 minutes to release the network interface. The script already retries for ~2 minutes. If it still fails, re-run the script.

**"AccessDenied" in GitHub Actions** — Re-check the policies attached to `github-actions-deployer` in Step 5.

---

## What each piece is (very short glossary)

- **ECR** — AWS's private Docker image registry.
- **ECS** — AWS's container orchestrator (think: runs your Docker containers for you).
- **Fargate** — The ECS mode where AWS manages the servers, so you don't.
- **Task definition** — The recipe: "run *this* image with *these* resources."
- **Service** — The thing that says "keep 1 of these tasks running at all times."
- **Security group** — A firewall around your container.
- **IAM role** — An identity AWS services use to talk to each other (e.g., ECS pulling from ECR).
