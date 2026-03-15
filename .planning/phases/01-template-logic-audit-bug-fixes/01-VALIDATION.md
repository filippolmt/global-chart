---
phase: 1
slug: template-logic-audit-bug-fixes
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-15
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | helm-unittest via Docker (`helmunittest/helm-unittest:3.19.0-1.0.3`) |
| **Config file** | `charts/global-chart/tests/` (test suites) |
| **Quick run command** | `make lint-chart` |
| **Full suite command** | `make lint-chart && make unit-test` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `make lint-chart`
- **After every plan wave:** Run `make lint-chart && make unit-test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| TBD | TBD | TBD | TMPL-01 | unit | `make lint-chart && make unit-test` | ✅ | ⬜ pending |
| TBD | TBD | TBD | TMPL-02 | unit | `make unit-test` | ✅ | ⬜ pending |
| TBD | TBD | TBD | TMPL-03 | unit | `make unit-test` | ✅ | ⬜ pending |
| TBD | TBD | TBD | TMPL-04 | unit | `make lint-chart && make unit-test` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Existing infrastructure covers all phase requirements. helm-unittest and lint are already configured.

---

## Manual-Only Verifications

All phase behaviors have automated verification via helm-unittest and helm lint.

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
