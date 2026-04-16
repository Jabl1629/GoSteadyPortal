# Phase {X}{Y} — {Title}

## Overview
- **Phase**: {0A | 1A | 1B | ...}
- **Status**: {Planned | In Progress | Deployed | Verified}
- **Branch**: feature/{branch-name}
- **Date Started**: YYYY-MM-DD
- **Date Completed**: YYYY-MM-DD

One-paragraph summary of what this phase delivers and why it matters.

## Locked-In Requirements
> Decisions finalized in this or prior phases that CANNOT change without
> cascading impact. Treat as immovable constraints.

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | ... | Phase XX | ... |

## Assumptions
> Beliefs we're building on that haven't been fully validated.
> If any prove wrong, flag immediately — they may invalidate this phase.

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | ... | ... | ... |

## Scope

### In Scope
- Bulleted list of what this phase delivers

### Out of Scope (Deferred)
- Bulleted list of what is explicitly NOT in this phase and where it lands

## Architecture

### Infrastructure Changes
- New stacks, resources, or modifications to existing stacks
- Include CDK stack names and resource logical IDs where relevant

### Data Flow
- How data moves through the system in this phase
- Diagram (Mermaid or ASCII) if helpful

### Interfaces
- APIs, MQTT topics, event schemas, DynamoDB access patterns touched

## Implementation

### Files Changed / Created
| File | Change Type | Description |
|------|------------|-------------|
| `path/to/file` | New / Modified | What changed |

### Dependencies
- What must exist before this phase can deploy (prior phases, external setup)
- NPM / pub packages added

### Configuration
- Environment variables, CDK context values, feature flags

## Testing

### Test Scenarios
| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | ... | CLI / Console / Unit | ... | Pass / Fail / Pending |

### Verification Commands
```bash
# Actual commands someone can run to verify this phase works
```

## Deployment

### Deploy Commands
```bash
# Exact commands to deploy this phase
```

### Rollback Plan
- How to undo if something goes wrong

## Decisions Log
> Choices made during this phase that affect future work.

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | ... | ... | ... |

## Open Questions
- [ ] Unresolved items to revisit before next phase

## Changelog
| Date | Author | Change |
|------|--------|--------|
| YYYY-MM-DD | ... | Initial spec |
