---
title: "Tag-Driven Ticket Loop: A ClickUp-to-PR Bot in Claude Code"
date: "2026-04-17T23:10:00.000Z"
template: "post"
draft: false
slug: "claude-ticket-loop"
category: "tooling"
tags:
  - "claude-code"
  - "automation"
  - "clickup"
  - "slash-commands"
description: "A Claude Code slash command that drains every tagged ticket from a ClickUp list — plans, implements across two repos, opens PRs, reports back — one ticket at a time, until none are left. The tag is the trigger; the loop is in the prompt."
socialImage: "/media/claude-ticket-loop.jpg"
---

![Tag-Driven Ticket Loop: A ClickUp-to-PR Bot in Claude Code](/media/claude-ticket-loop.jpg)

The contract is simple: add a tag in ClickUp, and Claude Code picks the ticket up. Add ten tags, it works through ten tickets. Add none, it does nothing. The slash command below implements that — it filters a ClickUp list for a trigger tag, picks the oldest eligible ticket, plans the fix *before* touching code, branches the repos it needs, opens PRs, writes a structured completion report back to the ticket, and then **re-queries the list** and does it again. It stops only when the list is empty. Pair it with the [sandbox from the previous post](https://rpy3.com/posts/claude-code-sandbox) — long-lived container, scoped `GH_TOKEN`, wide allowlist — and you get something that actually drains a backlog without blowing up the laptop it runs on.

The tag is the API. The loop is in the prompt. The scheduler (if any) just wakes the whole thing up.

## Design constraints

- **One ticket at a time, sequentially.** Never process two tickets in parallel. A failure on ticket N must not leave ticket N+1 half-done.
- **Claim tags are load-bearing.** `claude_in_progress` added *first*, before any code moves. A tick that crashes mid-flight leaves the tag in place so a human sees the abandoned claim.
- **Re-query between tickets.** Don't snapshot the list at the top and march through it. Someone may have removed the tag to cancel, or added urgent tickets. Re-filtering makes both work.
- **Hard caps.** Max tickets per run, max wall-clock per run, hard-stop on any unrecoverable error. A loop without brakes is a footgun with a loop on it.

## The command

Claude Code slash commands are just markdown files under `~/.claude/commands/` with a frontmatter `description` and a body that becomes the prompt. Here's the loop, trimmed to the load-bearing structure:

````markdown
---
description: Drain every tagged ticket from a ClickUp list — plan, branch, PR, report — one ticket at a time until the queue is empty.
---

You are running a ticket-processing loop. Process eligible tickets **one at
a time, sequentially**, until no eligible tickets remain or a stop condition
is hit. Never process two tickets in parallel.

## Fixed config (do not change)

- **ClickUp list ID:** `<LIST_ID>`
- **Required tags on a task:** `claude_code` AND `<project-tag>`
- **Skip tags (already claimed):** `claude_in_progress`, `claude_pr_opened`
- **Repo A:** `/workspace/repo-a`
- **Repo B:** `/workspace/repo-b`
- **Default PR base branch:** `<default-base>`
- **Max tickets per run:** 10
- **Hard-stop on any Error outcome** (don't try the next ticket after a failure).

## Outer loop

Repeat until one of these is true, then STOP:

- zero eligible tickets remain (print `Queue drained` and exit), OR
- you have processed 10 tickets in this run (print `Per-run cap reached`), OR
- any single ticket ended in an Error outcome (print `Stopped after error on <task-id>`).

Each iteration runs Steps 1–5 for exactly one ticket.

---

## Step 1 — Find one eligible ticket (re-query each iteration)

Call `clickup_filter_tasks` on the list *fresh every iteration* — do not
cache the list from a previous iteration. Filter tasks that have BOTH
required tags and NEITHER skip tag.

- If zero eligible: exit the outer loop with `Queue drained`.
- Otherwise pick the **oldest** by `date_created`. Store its ID as
  `$TASK_ID`. Do not pick more than one per iteration.

## Step 2 — Claim the ticket

Order matters — tag first so a concurrent run (or crash) can't double-pick.

1. Add tag `claude_in_progress` to `$TASK_ID`.
2. Move status to `in progress` (closest analog; don't abort on status failure).

## Step 3 — Read the ticket fully

Pull the full description + comments. Decide:

- **Bug or feature?** prefix = `bugfix/` or `feature/`
- **Base branch:** honor any explicit mention, else the default.
- **Branch name:** `<prefix>/<task-id>-<kebab-slug>`, slug ≤ 40 chars.

## Step 3.5 — Post the plan BEFORE touching any repo

Post a ClickUp comment with this exact structure:

    **Plan (Claude Code)**
    **Understanding:** <1–3 sentences>
    **Branch:** `<branch>` → base `<base>`
    **Repo A changes:** <bulleted list, or "No changes needed — <reason>">
    **Repo B changes:** <bulleted list, or "No changes needed — <reason>">
    **Verification:** <tests/builds per repo>

    _Remove `claude_in_progress` to cancel before this iteration finishes._

Only continue after this comment is posted successfully.

## Step 4 — Work on both repos (sequentially)

For each repo in order:

1. `cd` in, `git fetch origin`, `git checkout <base>`, `git pull --ff-only`.
2. If the plan said "No changes needed" with a solid reason, skip this repo
   entirely (no branch, no PR) — record as a clean skip.
3. Otherwise `git checkout -b <branch-name>`.
4. Implement the fix. Targeted edits only. Follow the repo's existing
   conventions. Don't add "explaining the fix" comments in code.
5. Verify: repo-appropriate lint / typecheck / tests. Fix what you broke;
   note pre-existing failures but don't fix them in this PR.
6. `git add -A` → commit `<type>: <title> (<task-id>)` → push.
7. `gh pr create --base <base> --head <branch>` with a body that links back
   to the ticket and lists a test plan.

### Failure handling inside Step 4

If any step fails (can't fix build, push rejected, `gh pr create` errors):

1. Post an `**Error (Claude Code)**` comment on the ticket with the failing
   repo, the step, and trimmed error output (~30 lines max).
2. Remove the `claude_in_progress` tag so a human / next run can retry.
3. **Hard-stop the outer loop** — do not start the next ticket. Print
   `Stopped after error on <task-id>` and exit.

## Step 5 — Close the ticket (structured completion report)

Only if Step 4 completed for both repos (or one was a clean skip):

1. Add tag `claude_pr_opened`.
2. Move status to `in review`.
3. Post a `**Done (Claude Code)**` comment with:
   - PR URLs (or "No changes needed — <reason>") for each repo
   - Branch names
   - 2–6 sentences on what actually changed and why
   - Files touched, per repo
   - Verification commands + pass/fail, per repo
   - Deviations from the Step 3.5 plan (or "None")

Return to the top of the outer loop (Step 1) for the next iteration.

## Final reminders

- **Sequential, never parallel.** One ticket must fully finish before the
  next starts.
- **Re-query each iteration.** Do not reuse the filtered list from the
  previous iteration — cancellations and new tags take effect immediately.
- **Never force-push.** Never `git reset --hard` shared branches. Never
  skip hooks.
- **Never merge the PR.** Human review is required.
- **Ambiguous ticket** → post a clarification-request comment, remove
  `claude_in_progress`, SKIP to the next iteration (not a hard stop —
  ambiguity is a per-ticket signal, not a queue-wide one).
````

## The parts that aren't obvious

A few design choices that look fussy on the first read but earn their keep:

- **Re-query between tickets, don't cache the list.** The tag is the API. If a human removes `claude_code` from ticket #3 between iterations, the agent must respect that on the next filter. Caching the initial list breaks the contract.
- **Hard-stop on error, skip on ambiguity.** An *error* (build break, push rejected, MCP tool failure) means the bot's execution model is broken — trying the next ticket will probably break the same way, and noise compounds. An *ambiguity* (conflicting comments, missing info) is a per-ticket signal — skip it and try the next one. The loop treats these differently on purpose.
- **Tag-before-status, always.** If tagging succeeds but status fails, the ticket is claimed and future iterations skip it — safe. If status succeeds but tagging fails, two runs could pick the same ticket — unsafe. So we tag first and tolerate status failures.
- **Plan before code (Step 3.5).** The plan comment is written *before* anything branches. This gives a human an interrupt window: remove `claude_in_progress` and the current iteration (if still mid-flight) can cancel cleanly, and future iterations won't re-pick.
- **Per-run cap.** 10 tickets is arbitrary but finite. Without it, a queue of 200 misconfigured tickets becomes 200 error comments and a surprise API bill. Pick a number you'd be okay walking into the next morning.
- **Clean skips are first-class.** Lots of tickets only need work in one repo. The command explicitly supports "No changes needed — <reason>" as an outcome, recorded in both the plan and the done comment. Without this, the agent invents busywork in the second repo to avoid looking like it failed.

## Running it

The command loops internally, so no external scheduler is required — just launch once and let it drain.

```bash
# Manual: run inside the sandbox from the previous post
./sandbox/run-agent.sh
# then inside claude:
> /clickup-tick

# Non-interactive (cron / CI / scheduled wake)
./sandbox/run-agent.sh claude -p '/clickup-tick'

# Periodic wake-up for continuous draining. /loop just fires /clickup-tick
# — the loop inside the prompt does the real work; /loop handles the gap
# between "queue empty now" and "new tickets tagged later".
> /loop 30m /clickup-tick
```

Two scheduling styles work:

- **Run-on-demand.** Humans tag a batch of tickets, then kick off the command. It drains what's there and exits. Predictable, easy to reason about cost.
- **Periodic sweep.** A `/loop 30m /clickup-tick` or cron drives the bot every 30 min. Each wake-up: if the queue is empty it exits in seconds; if tickets are waiting it drains them. More hands-off, but you're on the hook for whatever gets tagged in your sleep.

Both rely on the same invariant: the command itself always terminates (queue drained, per-run cap, or hard-stop on error). That's what makes it safe to wake repeatedly.

## Possible risks

Same framing as the sandbox post: blast-radius reduction, not trust-building.

## When it's working

When it's working, tagging a ticket and walking away results in, a few minutes later, two PR links and a completion report on the ticket — and then silence if the queue is empty, or the next ticket starting if it isn't. When it's not working, `claude_in_progress` gets dropped, a clarification or error comment sits on the ticket, and the outer loop stopped cleanly. The failure mode you *don't* want — a half-done PR set with no record of what happened — is the one this design is specifically built to prevent.

Quote

> _Make each program do one thing well. To do a new job, build afresh rather than complicate old programs by adding new features._
>
> — Doug McIlroy, "Basics of the Unix Philosophy"
