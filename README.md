# chokepoint-demo

A deliberately vulnerable demo Terraform account — the target that
[Chokepoint](https://github.com/Samir-Khadka/chokepoint) scans and opens
generated fix PRs against.

## What is in here

`main.tf` defines a small AWS account with the exact shape of Chokepoint's
demo inventory: a public EC2 web server whose over-permissioned role can read
a backups bucket holding the production database credentials, an assumable
admin role, and a public customer-data bucket.

## Warning

This is **intentionally insecure demo code**. Do not apply it to a real AWS
account. The "credential" stored in the backups bucket is a fake placeholder
string (`placeholder-credential-not-real`), not a real secret.

## How the demo works

1. Chokepoint scans this account (read-only) and finds the attack paths from
   the public Internet to the production database and the customer-data bucket.
2. `chokepoint top-fixes` ranks the fixes by how many paths each one removes.
3. `chokepoint fix` generates a validated Terraform change — for example,
   detaching the over-permissioned role from the web server, which removes
   3 of the 4 paths — and writes a PR body with the before/after graph.
4. That change is opened as a pull request here, so the full loop (scan →
   rank → fix → PR) is visible end to end.
