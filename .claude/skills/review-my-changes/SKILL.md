---
name: review-my-changes
description: Review local Unity changes (C# scripts, scenes, prefabs, assets), ask the developer about unclear behavior and which changes they approve, then commit ONLY the approved files to a feature branch, push, and open a pull request to main. Use when the user says "review my changes", "/review-my-changes", or asks to publish/ship their Unity work.
---

# Review My Changes

Unity 6 project (6000.3.5f1, URP, **new Input System only** — `activeInputHandler: 1`),
C# edited in VS Code, tested in the Unity Editor. Two developers; `main` is protected and
only changes through reviewed pull requests.

**Golden rule: nothing is committed, pushed, or opened as a PR until the user explicitly
approves in this conversation.** Saving a file, running this skill, or earlier approvals
never count as approval for the current set of changes.

## 1. Detect changes

```powershell
./Tools/Git/ReviewMyChanges.ps1 -Mode Status
```

Report the current branch, how it compares with `origin/main`, the changes grouped by
category, and any warnings. If there are no changes, say so and stop.

If `origin/main` has new commits, mention it and offer `git pull` (on main) or
`git merge origin/main` (on a feature branch) — only with the user's OK.

## 2. Review

Read the full diff (`git diff`, plus full contents of new untracked files). For every
changed `.cs` file check:

- **Compile risks**: missing `using`, wrong namespace, class name ≠ file name for
  MonoBehaviours/ScriptableObjects, editor-only APIs (`UnityEditor`) outside an `Editor`
  folder or `#if UNITY_EDITOR`.
- **Input**: legacy `Input.GetKey`/`Input.GetAxis` throws at runtime in this project —
  must use the Input System (`InputAction`, `PlayerInput`, `Keyboard.current`, …).
- **Lifecycle**: init order (`Awake` vs `Start`), `OnEnable`/`OnDisable` subscribe/unsubscribe
  pairs, coroutines stopped on disable.
- **Frame correctness**: physics/Rigidbody work in `FixedUpdate`; `Time.deltaTime` for
  frame-rate independence; no `GetComponent`/`Find*`/`new` allocations in `Update`.
- **Null safety**: `[SerializeField]` references that may be unassigned in the Inspector,
  `TryGetComponent`, destroyed-object checks.
- **Style**: `[SerializeField] private` over public fields, clear names, leftover
  `Debug.Log` spam, dead code, magic numbers that should be serialized.

For non-code files:
- Every added/deleted/renamed file under `Assets/` needs its `.meta` change too.
- Scenes/prefabs: note which ones changed — conflicts here are painful, so flag if the
  same scene is likely being edited by the other developer.
- Large binaries must be in LFS (the status warnings show this).
- `ProjectSettings/` and `Packages/` changes affect both developers — call them out.

Present findings ranked by severity (bugs → risks → suggestions), each with file:line
and a concrete fix. Do not edit files unless the user asks.

## 3. Ask about unclear behavior

When intent isn't obvious from the code (e.g. "jump height is 2 here but 5 in the
prefab — which is right?", "should this also work while airborne?"), ask before going
further. Use AskUserQuestion when there are clear options.

## 4. Ask which changes to approve

Use AskUserQuestion (multiSelect) listing the changes grouped into logical units
(e.g. "Player movement script + meta", "SampleScene edits", "Input actions asset").
Keep each asset and its `.meta` together. Also ask for (or propose) a short feature name
for the branch.

Unapproved changes stay untouched in the working tree.

## 5. Publish the approved changes

Branch name: `<prefix>/<short-feature>` where prefix comes from
`git config review.branchPrefix` (ask once and set it locally if missing),
e.g. `aryan/player-movement`.

If already on a feature branch with an open PR, ask whether to add to that PR or start a
new branch.

Write three files in the session scratchpad (never in the repo):
- `files.txt` — approved paths, one per line, exactly as `git status` shows them
- `msg.txt` — commit message: imperative summary line, blank line, short body explaining
  *why*, then the commit attribution trailer
- `body.md` — PR body: **What**, **Why**, **How to test in the Editor** (scene to open,
  steps, expected result), **Review notes** (risks from step 2)

Show the user the branch name, file list, and commit message, then run:

```powershell
./Tools/Git/ReviewMyChanges.ps1 -Mode Publish -Approved -Branch <branch> `
  -FileList <files.txt> -MessageFile <msg.txt> -Title "<PR title>" -BodyFile <body.md>
```

Only pass `-Approved` after the user approved in step 4. The script refuses to publish to
`main`, stages only the listed files, and reports an existing PR instead of opening a
duplicate. It requests a review from `git config review.reviewer` and, when
`git config review.autoMerge` is `true`, turns on squash auto-merge (the PR still merges
only after the required approval).

## 6. Wrap up

Give the PR link, list what was left uncommitted, and remind the user that the other
developer must approve the PR on GitHub before it can merge (with auto-merge on, it then
merges by itself). After it merges:
`git switch main && git pull`.
