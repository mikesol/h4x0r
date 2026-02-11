# h4x0r

Haxe compile-time framework that eliminates the backend. The developer writes one Haxe class with annotations; the compiler produces client JS, Cloudflare Worker, Durable Object code, migration SQL, and config files.

See `VISION.md` for full architecture. See `docs/plans/` for design documents.

## How to build

```bash
haxe build.hxml
```

This produces dual targets: `gen/client.js` (browser) and `gen/server.js` (Cloudflare DO). Infrastructure artifacts (`gen/do.js`, `gen/worker.js`, `gen/wrangler.toml`, `gen/migrations/`, `gen/manifest.md`) are emitted by the macro during compilation.

## How to find work

```
gh issue list --milestone "<current phase>" --label "ready" --assignee ""
```

Pick an issue. Read it fully — especially **"Not in scope"**. Then:

1. Assign yourself: `gh issue edit <N> --add-assignee @me --remove-label ready --add-label in-progress`
2. Create a worktree: `git worktree add ../h4x0r-<N> -b issue-<N>`
3. Work in that worktree
4. PR back to main: `gh pr create` referencing `Closes #<N>`

## How to submit work

PR body must include:

- `Closes #<N>`
- **What this does**: 2-3 sentences
- **Spec compliance**: For each VISION.md section referenced in the issue, confirm how the implementation matches. Any deviation must reference an approved `spec-change` issue.
- **Validation performed**: What you tested against real Cloudflare/browser. Evidence, not claims.

## Standing rules

- **NEVER merge PRs without explicit user authorization.** Always wait for the user to say "merge it" (or equivalent).
- **Ejectability by design**: Generated artifacts must be independently runnable without the framework. Always.
- **SCAFFOLD code**: If you encounter code marked `SCAFFOLD`, don't modify/extend/build on it beyond its stated purpose. When you create scaffold code, add a `SCAFFOLD(phase, #issue)` comment and create a `scaffold-cleanup` issue.
- **Spec seems wrong?** STOP. Open a GitHub Issue labeled `spec-change` with: the problem (with evidence), affected VISION.md sections, proposed change, downstream impact. Don't build on a wrong assumption.
- **Real infrastructure only**: Validate against real Cloudflare (`wrangler`) and real browser. Not mocks.
- **No manual @:server/@:client on methods**: The compiler infers placement from method body analysis. Annotations are only for state (`@:shared`, `@:guard`) and infrastructure (`@:webhook`, `@:cron`, `@:after`, `@:store`, `@:auth`, `@:permit`).

## Required skills for all workflow operations

**You MUST use the superpowers skills for brainstorming, planning, worktree management, and sub-agent dispatch.** Do NOT hand-roll these operations with raw Task tool calls — the skills handle permissions, directory routing, and agent coordination correctly.

| Operation | Required skill |
|---|---|
| Creative/design work before implementation | `superpowers:brainstorming` |
| Writing implementation plans | `superpowers:writing-plans` |
| Creating/managing git worktrees | `superpowers:using-git-worktrees` |
| Dispatching parallel sub-agents | `superpowers:dispatching-parallel-agents` |
| Executing plans with sub-agents (same session) | `superpowers:subagent-driven-development` |
| Executing plans (separate session) | `superpowers:executing-plans` |
| Finishing a branch (merge/PR/cleanup) | `superpowers:finishing-a-development-branch` |
| Code review | `superpowers:requesting-code-review` |
| Verifying work before claiming done | `superpowers:verification-before-completion` |
| TDD workflow | `superpowers:test-driven-development` |

**Never** use `run_in_background: true` with the Task tool for implementation work. Background agents cannot prompt for permissions and will silently fail.

## Current phase

Phase 1: Foundation (Milestone: "Phase 1: Foundation")
