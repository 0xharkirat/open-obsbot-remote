# Factory charter

This file holds Hark's judgment for 1 project.
The factory agents read it before they act, and no agent changes it.
Every value that a script checks, such as the risky paths, the gates, and the size limit, is in `factory.json` next to this file.

## Status

The factory starts no job until this line says `ready`.
Read every section, change what is wrong for this project, then set it:

```text
CHARTER_STATUS: ready
```

## Tier

Keep 1 tier, and delete the other rows.
The tier tells the approver how careful to be when no router rule applies.

| Tier | Means | Approver |
|---|---|---|
| `revival` | No users yet. Migration and revival work. | Sends a job to Hark only for a real doubt. |
| `greenfield` | A personal project. No user depends on it yet. | Sends a job to Hark for a doubt about the design. |
| `oss` | Published. Other people depend on it. | Sends a job to Hark for any change to a public API. |
| `client-production` | Someone else's business depends on it. | Sends a job to Hark for any doubt at all. |

The tier tracks who gets hurt by a mistake, not how hard the change is.

## What to automate

Intake reads these lists to decide what happens to a task.
Make each line specific: a vague line gives a vague decision.

```text
AUTOMATABLE:
  - Lint, format, and type fixes
  - Docs and comment fixes
  - Tests for existing code that has no test
  - A bug fix with a test that fails before the fix
  - A dependency bump that passes the full gates

NEEDS_SPEC:
  - A new feature that a user can see
  - A change to a public API or an exported type
  - A change to more than 5 files
  - A change to a risky path in factory.json

NEVER_AUTOMATE:
  - A merge
  - A choice of architecture or of a new dependency
  - A decision about whether a feature should exist
  - Any task that no list in this file covers
```

The last line matters: a task that no list covers stops and goes to Hark.

## Extra done rules

The factory's done rule always applies.
It needs GREEN gates, a test that fails without the change, a clean review round, and a diff that does only the task.
Add the rules that this project needs on top, for example:

```text
DONE_EXTRA:
  - A UI change has a before and an after screenshot in the PR
```

## Notes for reviewers

Every review lens reads these notes.
Write facts that a reviewer can't find in the code, for example "the portal needs a saved sign-in" or "the scan job costs money, so never start it".

```text
REVIEWER_NOTES:
  - none yet
```

## Review dates

The monthly prune proposal reads these dates.
Tighten a rule as soon as a defect gets past it.
Loosen a rule only after a long run of green jobs, and write that run down.

```text
LAST_REVIEWED: YYYY-MM-DD
NEXT_REVIEW: YYYY-MM-DD
```
