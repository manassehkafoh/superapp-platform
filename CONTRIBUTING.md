# Contributing to SuperApp Platform

## Getting Started
1. Read the [Onboarding Guide](docs/onboarding/JUNIOR-ENGINEER-ONBOARDING.md)
2. Pick a ticket from the Jira board tagged `good-first-issue`
3. Create a branch: `git checkout -b feature/SUPER-<ticket>-<description>`

## Development Workflow
```bash
make local-up          # start local infrastructure
make run SERVICE=payment-api  # run a service
make test-unit         # run unit tests
make lint              # lint with warnings-as-errors
make security-scan     # TruffleHog + Trivy
```

## Commit Convention
We use [Conventional Commits](https://www.conventionalcommits.org/):
```
feat(payment-api): add daily limit validation
fix(wallet-api): correct balance calculation for zero entries
docs: update onboarding guide for k3d setup
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `security`

## PR Requirements
- 2 approvals (1 must be a squad senior)
- All CI checks green
- Coverage ≥ 80% for new code
- PR template filled out completely
- No secrets committed (TruffleHog blocks this)

## Code Standards
See [Coding Standards](docs/onboarding/JUNIOR-ENGINEER-ONBOARDING.md#8-coding-standards--conventions)

## Security
See [SECURITY.md](SECURITY.md) for vulnerability reporting.
