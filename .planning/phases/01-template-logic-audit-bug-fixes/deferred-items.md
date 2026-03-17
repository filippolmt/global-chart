# Deferred Items - Phase 01

## Pre-existing Issues Found During 01-02 Execution

1. **hook_test.yaml has uncommitted test additions from plan 01-01**
   - Uncommitted tests for hook weight ordering (prerequisite ConfigMap/Secret weight "3")
   - These tests fail because the corresponding template changes may not be committed
   - Files: `charts/global-chart/tests/hook_test.yaml`
   - Action: Should be addressed in plan 01-01 completion or 01-03

2. **`.gitignore` has uncommitted change adding `.planning/`**
   - File: `.gitignore`
   - Action: Should be committed as part of project setup
