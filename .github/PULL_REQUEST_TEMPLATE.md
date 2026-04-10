## Description
<!-- What does this PR do? Link the ticket: Closes SUPER-XXX -->

## Type of Change
- [ ] feat: New feature
- [ ] fix: Bug fix
- [ ] refactor: Code refactor (no behaviour change)
- [ ] docs: Documentation only
- [ ] chore: Build, CI, dependencies
- [ ] security: Security fix (notify #superapp-security)

## Testing
- [ ] Unit tests added/updated and passing (`make test-unit`)
- [ ] Coverage ≥ 80% for new code
- [ ] Integration tests run (`make test-integration`) if applicable

## Security Checklist
- [ ] No hardcoded secrets, tokens, or API keys
- [ ] No sensitive data in log statements (no passwords, card numbers)
- [ ] All new endpoints have `[Authorize]` or explicit `[AllowAnonymous]`
- [ ] Input validation on all request fields
- [ ] New external HTTP calls use named HttpClient factory

## Deployment Notes
<!-- Any DB migrations? Config changes? Rollback steps? -->

## SOC 2 / DORA Impact
<!-- Does this change affect any compliance controls? -->
- [ ] No compliance impact
- [ ] Affects access control (CC6.1)
- [ ] Affects audit logging (CC7.2)
- [ ] Affects secrets management (CC6.3)
- [ ] Affects incident response (DORA Art.17)
