# GitHub Project Setup

## Repository hygiene

- `.gitignore` is included for Terraform state, generated files, and local secrets.
- Keep `.env.local` out of git; use `.env.local.example` as template.

## Recommended repo files

- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/DEPLOYMENT.md`
- `docs/REFERENCES.md`

## Suggested GitHub project columns

1. Backlog
2. Ready
3. In Progress
4. Review
5. Done

## Suggested issues to create

1. Validate OCI Logging -> Streaming connector for target compartment
2. Validate Kafka Connect sink lifecycle and restart policy
3. Add integration test for HEC ingest event after deployment
4. Add optional existing Splunk mode for Resource Manager stack UI
