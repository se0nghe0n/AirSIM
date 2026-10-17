---
description: Run the minimal sufficient checks from AGENTS.md「标准验证」for the current changes
argument-hint: "[scope]"
---
Read the `## 标准验证` section of AGENTS.md. For the current diff (or the scope `${@:-current changes}`), pick the minimal sufficient subset of those commands, run them, and report each command with pass/fail. Do not run `wrangler secret put`, production deploys, or anything else that changes external state.
