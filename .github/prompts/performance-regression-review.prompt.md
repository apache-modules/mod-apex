---
description: "Review a planned or existing mod_apex change for performance and correctness regressions before merge."
name: "Performance Regression Review"
argument-hint: "Paste a diff, commit hash, or describe proposed change"
agent: "agent"
---
You are reviewing a change for [mod_apex.c](../../mod_apex.c) and related Apache/PHP embed integration.

Input:
{{input}}

Tasks:
1. Identify regression risks first, ordered by severity.
2. Focus on request lifecycle correctness, thread safety, callback semantics, and output/header behavior.
3. Flag potential throughput or latency regressions (extra allocations, blocking paths, redundant work).
4. Call out compatibility risks with Apache 2.4 event MPM and PHP embed ZTS assumptions.
5. Suggest the smallest safe patch strategy, not a rewrite.
6. Provide a validation plan using repo commands and files.

Output format:
- Findings (Critical/High/Medium/Low)
- Why each finding matters
- Minimal fix approach
- Validation steps
- Residual risks and assumptions
