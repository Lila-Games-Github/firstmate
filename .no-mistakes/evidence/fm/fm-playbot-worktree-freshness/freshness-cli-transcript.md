# Playbot lane freshness: end-user CLI transcript

Fixture: real Git repo `FrogPile` whose landing branch is `proto/godot/frog-pile` (remote also has a `main`, which must never be assumed). Four lane worktrees: clean, ahead (2 unlanded commits), behind (1), diverged (1/1). Paths under the temp fixture are shown as `<fixture>`.

## get_workspace_freshness: ws-clean

```
$ fm-playbot-lanes call get_workspace_freshness '{"project":"FrogPile","workspace":"ws-clean","landingBranch":"proto/godot/frog-pile"}'
{
  "content": [
    {
      "type": "text",
      "text": "{\n  \"freshness\": {\n    \"workspace\": {\n      \"id\": \"ws-clean\",\n      \"name\": \"lane-clean\",\n      \"kind\": \"worktree\",\n      \"projectId\": \"project-frogpile\",\n      \"project\": \"FrogPile\"\n    },\n    \"landingBranch\": \"proto/godot/frog-pile\",\n    \"current\": true,\n    \"roots\": [\n      {\n        \"projectRootId\": \"root-frogpile\",\n        \"worktreePath\": \"<fixture>/frog-pile/.worktrees/clean\",\n        \"head\": {\n          \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n          \"subject\": \"landing advance\"\n        },\n        \"landingBranch\": \"proto/godot/frog-pile\",\n        \"landingBranchTip\": {\n          \"requested\": \"proto/godot/frog-pile\",\n          \"remote\": \"origin\",\n          \"branch\": \"proto/godot/frog-pile\",\n          \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n          \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n          \"observedAt\": \"2026-09-03T19:02:13.020Z\",\n          \"presentLocally\": true\n        },\n        \"relation\": \"equal\",\n        \"distanceKnown\": true,\n        \"commitsAhead\": 0,\n        \"commitsBehind\": 0,\n        \"current\": true,\n        \"headIsCleanFastForwardOfLandingTip\": true,\n        \"unlandedCommits\": []\n      }\n    ]\n  }\n}"
    }
  ],
  "structuredContent": {
    "freshness": {
      "workspace": {
        "id": "ws-clean",
        "name": "lane-clean",
        "kind": "worktree",
        "projectId": "project-frogpile",
        "project": "FrogPile"
      },
      "landingBranch": "proto/godot/frog-pile",
      "current": true,
      "roots": [
        {
          "projectRootId": "root-frogpile",
          "worktreePath": "<fixture>/frog-pile/.worktrees/clean",
          "head": {
            "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
            "subject": "landing advance"
          },
          "landingBranch": "proto/godot/frog-pile",
          "landingBranchTip": {
            "requested": "proto/godot/frog-pile",
            "remote": "origin",
            "branch": "proto/godot/frog-pile",
            "remoteRef": "refs/heads/proto/godot/frog-pile",
            "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
            "observedAt": "2026-09-03T19:02:13.020Z",
            "presentLocally": true
          },
          "relation": "equal",
          "distanceKnown": true,
          "commitsAhead": 0,
          "commitsBehind": 0,
          "current": true,
          "headIsCleanFastForwardOfLandingTip": true,
          "unlandedCommits": []
        }
      ]
    }
  }
}
```

## get_workspace_freshness: ws-ahead

```
$ fm-playbot-lanes call get_workspace_freshness '{"project":"FrogPile","workspace":"ws-ahead","landingBranch":"proto/godot/frog-pile"}'
{
  "content": [
    {
      "type": "text",
      "text": "{\n  \"freshness\": {\n    \"workspace\": {\n      \"id\": \"ws-ahead\",\n      \"name\": \"lane-ahead\",\n      \"kind\": \"worktree\",\n      \"projectId\": \"project-frogpile\",\n      \"project\": \"FrogPile\"\n    },\n    \"landingBranch\": \"proto/godot/frog-pile\",\n    \"current\": true,\n    \"roots\": [\n      {\n        \"projectRootId\": \"root-frogpile\",\n        \"worktreePath\": \"<fixture>/frog-pile/.worktrees/ahead\",\n        \"head\": {\n          \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n          \"subject\": \"tune pile physics\"\n        },\n        \"landingBranch\": \"proto/godot/frog-pile\",\n        \"landingBranchTip\": {\n          \"requested\": \"proto/godot/frog-pile\",\n          \"remote\": \"origin\",\n          \"branch\": \"proto/godot/frog-pile\",\n          \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n          \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n          \"observedAt\": \"2026-09-03T19:02:13.110Z\",\n          \"presentLocally\": true\n        },\n        \"relation\": \"ahead\",\n        \"distanceKnown\": true,\n        \"commitsAhead\": 2,\n        \"commitsBehind\": 0,\n        \"current\": true,\n        \"headIsCleanFastForwardOfLandingTip\": true,\n        \"unlandedCommits\": [\n          {\n            \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n            \"subject\": \"tune pile physics\"\n          },\n          {\n            \"commit\": \"820d172bc023a04c4e1d4b72036ae4bd8cf52c7f\",\n            \"subject\": \"add frog hop animation\"\n          }\n        ]\n      }\n    ]\n  }\n}"
    }
  ],
  "structuredContent": {
    "freshness": {
      "workspace": {
        "id": "ws-ahead",
        "name": "lane-ahead",
        "kind": "worktree",
        "projectId": "project-frogpile",
        "project": "FrogPile"
      },
      "landingBranch": "proto/godot/frog-pile",
      "current": true,
      "roots": [
        {
          "projectRootId": "root-frogpile",
          "worktreePath": "<fixture>/frog-pile/.worktrees/ahead",
          "head": {
            "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
            "subject": "tune pile physics"
          },
          "landingBranch": "proto/godot/frog-pile",
          "landingBranchTip": {
            "requested": "proto/godot/frog-pile",
            "remote": "origin",
            "branch": "proto/godot/frog-pile",
            "remoteRef": "refs/heads/proto/godot/frog-pile",
            "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
            "observedAt": "2026-09-03T19:02:13.110Z",
            "presentLocally": true
          },
          "relation": "ahead",
          "distanceKnown": true,
          "commitsAhead": 2,
          "commitsBehind": 0,
          "current": true,
          "headIsCleanFastForwardOfLandingTip": true,
          "unlandedCommits": [
            {
              "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
              "subject": "tune pile physics"
            },
            {
              "commit": "820d172bc023a04c4e1d4b72036ae4bd8cf52c7f",
              "subject": "add frog hop animation"
            }
          ]
        }
      ]
    }
  }
}
```

## get_workspace_freshness: ws-behind

```
$ fm-playbot-lanes call get_workspace_freshness '{"project":"FrogPile","workspace":"ws-behind","landingBranch":"proto/godot/frog-pile"}'
{
  "content": [
    {
      "type": "text",
      "text": "{\n  \"freshness\": {\n    \"workspace\": {\n      \"id\": \"ws-behind\",\n      \"name\": \"lane-behind\",\n      \"kind\": \"worktree\",\n      \"projectId\": \"project-frogpile\",\n      \"project\": \"FrogPile\"\n    },\n    \"landingBranch\": \"proto/godot/frog-pile\",\n    \"current\": false,\n    \"roots\": [\n      {\n        \"projectRootId\": \"root-frogpile\",\n        \"worktreePath\": \"<fixture>/frog-pile/.worktrees/behind\",\n        \"head\": {\n          \"commit\": \"c7eef4a138acbcbe58f0f802ec62c73d6cfde419\",\n          \"subject\": \"frog-pile baseline\"\n        },\n        \"landingBranch\": \"proto/godot/frog-pile\",\n        \"landingBranchTip\": {\n          \"requested\": \"proto/godot/frog-pile\",\n          \"remote\": \"origin\",\n          \"branch\": \"proto/godot/frog-pile\",\n          \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n          \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n          \"observedAt\": \"2026-09-03T19:02:13.210Z\",\n          \"presentLocally\": true\n        },\n        \"relation\": \"behind\",\n        \"distanceKnown\": true,\n        \"commitsAhead\": 0,\n        \"commitsBehind\": 1,\n        \"current\": false,\n        \"headIsCleanFastForwardOfLandingTip\": false,\n        \"unlandedCommits\": []\n      }\n    ]\n  }\n}"
    }
  ],
  "structuredContent": {
    "freshness": {
      "workspace": {
        "id": "ws-behind",
        "name": "lane-behind",
        "kind": "worktree",
        "projectId": "project-frogpile",
        "project": "FrogPile"
      },
      "landingBranch": "proto/godot/frog-pile",
      "current": false,
      "roots": [
        {
          "projectRootId": "root-frogpile",
          "worktreePath": "<fixture>/frog-pile/.worktrees/behind",
          "head": {
            "commit": "c7eef4a138acbcbe58f0f802ec62c73d6cfde419",
            "subject": "frog-pile baseline"
          },
          "landingBranch": "proto/godot/frog-pile",
          "landingBranchTip": {
            "requested": "proto/godot/frog-pile",
            "remote": "origin",
            "branch": "proto/godot/frog-pile",
            "remoteRef": "refs/heads/proto/godot/frog-pile",
            "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
            "observedAt": "2026-09-03T19:02:13.210Z",
            "presentLocally": true
          },
          "relation": "behind",
          "distanceKnown": true,
          "commitsAhead": 0,
          "commitsBehind": 1,
          "current": false,
          "headIsCleanFastForwardOfLandingTip": false,
          "unlandedCommits": []
        }
      ]
    }
  }
}
```

## get_workspace_freshness: ws-diverged

```
$ fm-playbot-lanes call get_workspace_freshness '{"project":"FrogPile","workspace":"ws-diverged","landingBranch":"proto/godot/frog-pile"}'
{
  "content": [
    {
      "type": "text",
      "text": "{\n  \"freshness\": {\n    \"workspace\": {\n      \"id\": \"ws-diverged\",\n      \"name\": \"lane-diverged\",\n      \"kind\": \"worktree\",\n      \"projectId\": \"project-frogpile\",\n      \"project\": \"FrogPile\"\n    },\n    \"landingBranch\": \"proto/godot/frog-pile\",\n    \"current\": false,\n    \"roots\": [\n      {\n        \"projectRootId\": \"root-frogpile\",\n        \"worktreePath\": \"<fixture>/frog-pile/.worktrees/diverged\",\n        \"head\": {\n          \"commit\": \"07b072b6dcdf07a37a91b8dd6395f75876f0aff8\",\n          \"subject\": \"diverged lane work\"\n        },\n        \"landingBranch\": \"proto/godot/frog-pile\",\n        \"landingBranchTip\": {\n          \"requested\": \"proto/godot/frog-pile\",\n          \"remote\": \"origin\",\n          \"branch\": \"proto/godot/frog-pile\",\n          \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n          \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n          \"observedAt\": \"2026-09-03T19:02:13.300Z\",\n          \"presentLocally\": true\n        },\n        \"relation\": \"diverged\",\n        \"distanceKnown\": true,\n        \"commitsAhead\": 1,\n        \"commitsBehind\": 1,\n        \"current\": false,\n        \"headIsCleanFastForwardOfLandingTip\": false,\n        \"unlandedCommits\": [\n          {\n            \"commit\": \"07b072b6dcdf07a37a91b8dd6395f75876f0aff8\",\n            \"subject\": \"diverged lane work\"\n          }\n        ]\n      }\n    ]\n  }\n}"
    }
  ],
  "structuredContent": {
    "freshness": {
      "workspace": {
        "id": "ws-diverged",
        "name": "lane-diverged",
        "kind": "worktree",
        "projectId": "project-frogpile",
        "project": "FrogPile"
      },
      "landingBranch": "proto/godot/frog-pile",
      "current": false,
      "roots": [
        {
          "projectRootId": "root-frogpile",
          "worktreePath": "<fixture>/frog-pile/.worktrees/diverged",
          "head": {
            "commit": "07b072b6dcdf07a37a91b8dd6395f75876f0aff8",
            "subject": "diverged lane work"
          },
          "landingBranch": "proto/godot/frog-pile",
          "landingBranchTip": {
            "requested": "proto/godot/frog-pile",
            "remote": "origin",
            "branch": "proto/godot/frog-pile",
            "remoteRef": "refs/heads/proto/godot/frog-pile",
            "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
            "observedAt": "2026-09-03T19:02:13.300Z",
            "presentLocally": true
          },
          "relation": "diverged",
          "distanceKnown": true,
          "commitsAhead": 1,
          "commitsBehind": 1,
          "current": false,
          "headIsCleanFastForwardOfLandingTip": false,
          "unlandedCommits": [
            {
              "commit": "07b072b6dcdf07a37a91b8dd6395f75876f0aff8",
              "subject": "diverged lane work"
            }
          ]
        }
      ]
    }
  }
}
```

## fail closed: landingBranch omitted (no default branch is ever assumed)

```
$ fm-playbot-lanes call get_workspace_freshness '{"project":"FrogPile","workspace":"ws-clean"}'
get_workspace_freshness requires an explicit landingBranch
# CLI exit status: 1 (MCP serve mode returns a JSON-RPC error object with the same message)
```

## fail closed: workspace selector omitted

```
$ fm-playbot-lanes call get_workspace_freshness '{"project":"FrogPile","landingBranch":"proto/godot/frog-pile"}'
get_workspace_freshness requires an explicit workspace selector by id, path, or name
```

## fail closed: worktree path missing on disk

```
$ fm-playbot-lanes call get_workspace_freshness '{"project":"FrogPile","workspace":"ws-missing","landingBranch":"proto/godot/frog-pile"}'
freshness is unreadable for workspace ws-missing root root-frogpile: workspace root is missing: <fixture>/frog-pile/.worktrees/missing
```

## fail closed: landing branch absent on the remote

```
$ fm-playbot-lanes call get_workspace_freshness '{"project":"FrogPile","workspace":"ws-clean","landingBranch":"proto/godot/does-not-exist"}'
freshness is unreadable for workspace ws-clean root root-frogpile: git exited 2
```

## remote-name prefix ambiguity: 'origin/main' is rejected

```
$ fm-playbot-lanes call get_workspace_freshness '{"project":"FrogPile","workspace":"ws-clean","landingBranch":"origin/main"}'
freshness is unreadable for workspace ws-clean root root-frogpile: landing branch origin/main is ambiguous because origin is a configured remote; use refs/remotes/origin/main to name the remote branch explicitly
```

## partial clone: remote tip not present locally, distance unknown, no fetch

```
$ fm-playbot-lanes call get_workspace_freshness '{"project":"partial-clone","workspace":"ws-partial","landingBranch":"main"}'
# before: is remote tip fc4204a841e2d8b6c573582b05ce6cf3fc5cebc1 present locally?  no
{
  "content": [
    {
      "type": "text",
      "text": "{\n  \"freshness\": {\n    \"workspace\": {\n      \"id\": \"ws-partial\",\n      \"name\": \"partial\",\n      \"kind\": \"worktree\",\n      \"projectId\": \"project-partial\",\n      \"project\": \"partial-clone\"\n    },\n    \"landingBranch\": \"main\",\n    \"current\": false,\n    \"roots\": [\n      {\n        \"projectRootId\": \"root-partial\",\n        \"worktreePath\": \"<fixture>/partial\",\n        \"head\": {\n          \"commit\": \"e5bd22ba46eb871e01f4f1aea74acb776bd79ba1\",\n          \"subject\": \"partial baseline\"\n        },\n        \"landingBranch\": \"main\",\n        \"landingBranchTip\": {\n          \"requested\": \"main\",\n          \"remote\": \"origin\",\n          \"branch\": \"main\",\n          \"remoteRef\": \"refs/heads/main\",\n          \"commit\": \"fc4204a841e2d8b6c573582b05ce6cf3fc5cebc1\",\n          \"observedAt\": \"2026-09-03T19:02:13.663Z\",\n          \"presentLocally\": false\n        },\n        \"relation\": \"behind-or-diverged\",\n        \"distanceKnown\": false,\n        \"commitsAhead\": null,\n        \"commitsBehind\": null,\n        \"current\": false,\n        \"headIsCleanFastForwardOfLandingTip\": false,\n        \"unlandedCommits\": null\n      }\n    ]\n  }\n}"
    }
  ],
  "structuredContent": {
    "freshness": {
      "workspace": {
        "id": "ws-partial",
        "name": "partial",
        "kind": "worktree",
        "projectId": "project-partial",
        "project": "partial-clone"
      },
      "landingBranch": "main",
      "current": false,
      "roots": [
        {
          "projectRootId": "root-partial",
          "worktreePath": "<fixture>/partial",
          "head": {
            "commit": "e5bd22ba46eb871e01f4f1aea74acb776bd79ba1",
            "subject": "partial baseline"
          },
          "landingBranch": "main",
          "landingBranchTip": {
            "requested": "main",
            "remote": "origin",
            "branch": "main",
            "remoteRef": "refs/heads/main",
            "commit": "fc4204a841e2d8b6c573582b05ce6cf3fc5cebc1",
            "observedAt": "2026-09-03T19:02:13.663Z",
            "presentLocally": false
          },
          "relation": "behind-or-diverged",
          "distanceKnown": false,
          "commitsAhead": null,
          "commitsBehind": null,
          "current": false,
          "headIsCleanFastForwardOfLandingTip": false,
          "unlandedCommits": null
        }
      ]
    }
  }
}
# after:  is remote tip present locally?  no   (still absent => no lazy fetch happened)
```

## malformed PLAYBOT_LANES_REMOTE_GIT_TIMEOUT_MS is a configuration error, not a landing-branch failure

```
$ PLAYBOT_LANES_REMOTE_GIT_TIMEOUT_MS=abc fm-playbot-lanes call get_workspace_freshness ...
freshness is unreadable for workspace ws-clean root root-frogpile: configuration error: PLAYBOT_LANES_REMOTE_GIT_TIMEOUT_MS must be a positive integer
```

## get_thread_status carries the same freshness reading

```
$ fm-playbot-lanes call get_thread_status '{"project":"FrogPile","thread":"Hop animation","landingBranch":"proto/godot/frog-pile"}'
{
  "content": [
    {
      "type": "text",
      "text": "{\n  \"thread\": {\n    \"id\": \"chat-ahead\",\n    \"title\": \"Hop animation\",\n    \"projectId\": \"project-frogpile\",\n    \"project\": \"FrogPile\",\n    \"workspaceId\": \"ws-ahead\",\n    \"workspace\": \"lane-ahead\",\n    \"sessionId\": \"sess-ahead\",\n    \"status\": \"pending_input\",\n    \"queuedCount\": 0,\n    \"hasUnread\": false,\n    \"isActive\": true,\n    \"archived\": false,\n    \"updatedAt\": \"2026-09-03T19:02:12.941Z\",\n    \"url\": \"playbot://workspace/ws-ahead/thread/chat-ahead\"\n  },\n  \"freshness\": {\n    \"workspace\": {\n      \"id\": \"ws-ahead\",\n      \"name\": \"lane-ahead\",\n      \"kind\": \"worktree\",\n      \"projectId\": \"project-frogpile\",\n      \"project\": \"FrogPile\"\n    },\n    \"landingBranch\": \"proto/godot/frog-pile\",\n    \"current\": true,\n    \"roots\": [\n      {\n        \"projectRootId\": \"root-frogpile\",\n        \"worktreePath\": \"<fixture>/frog-pile/.worktrees/ahead\",\n        \"head\": {\n          \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n          \"subject\": \"tune pile physics\"\n        },\n        \"landingBranch\": \"proto/godot/frog-pile\",\n        \"landingBranchTip\": {\n          \"requested\": \"proto/godot/frog-pile\",\n          \"remote\": \"origin\",\n          \"branch\": \"proto/godot/frog-pile\",\n          \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n          \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n          \"observedAt\": \"2026-09-03T19:02:13.809Z\",\n          \"presentLocally\": true\n        },\n        \"relation\": \"ahead\",\n        \"distanceKnown\": true,\n        \"commitsAhead\": 2,\n        \"commitsBehind\": 0,\n        \"current\": true,\n        \"headIsCleanFastForwardOfLandingTip\": true,\n        \"unlandedCommits\": [\n          {\n            \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n            \"subject\": \"tune pile physics\"\n          },\n          {\n            \"commit\": \"820d172bc023a04c4e1d4b72036ae4bd8cf52c7f\",\n            \"subject\": \"add frog hop animation\"\n          }\n        ]\n      }\n    ]\n  },\n  \"lanes\": []\n}"
    }
  ],
  "structuredContent": {
    "thread": {
      "id": "chat-ahead",
      "title": "Hop animation",
      "projectId": "project-frogpile",
      "project": "FrogPile",
      "workspaceId": "ws-ahead",
      "workspace": "lane-ahead",
      "sessionId": "sess-ahead",
      "status": "pending_input",
      "queuedCount": 0,
      "hasUnread": false,
      "isActive": true,
      "archived": false,
      "updatedAt": "2026-09-03T19:02:12.941Z",
      "url": "playbot://workspace/ws-ahead/thread/chat-ahead"
    },
    "freshness": {
      "workspace": {
        "id": "ws-ahead",
        "name": "lane-ahead",
        "kind": "worktree",
        "projectId": "project-frogpile",
        "project": "FrogPile"
      },
      "landingBranch": "proto/godot/frog-pile",
      "current": true,
      "roots": [
        {
          "projectRootId": "root-frogpile",
          "worktreePath": "<fixture>/frog-pile/.worktrees/ahead",
          "head": {
            "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
            "subject": "tune pile physics"
          },
          "landingBranch": "proto/godot/frog-pile",
          "landingBranchTip": {
            "requested": "proto/godot/frog-pile",
            "remote": "origin",
            "branch": "proto/godot/frog-pile",
            "remoteRef": "refs/heads/proto/godot/frog-pile",
            "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
            "observedAt": "2026-09-03T19:02:13.809Z",
            "presentLocally": true
          },
          "relation": "ahead",
          "distanceKnown": true,
          "commitsAhead": 2,
          "commitsBehind": 0,
          "current": true,
          "headIsCleanFastForwardOfLandingTip": true,
          "unlandedCommits": [
            {
              "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
              "subject": "tune pile physics"
            },
            {
              "commit": "820d172bc023a04c4e1d4b72036ae4bd8cf52c7f",
              "subject": "add frog hop animation"
            }
          ]
        }
      ]
    },
    "lanes": []
  }
}
```

## list_parked_threads global scope with per-project landing map (partial-clone project uncovered => no freshness fields)

```
$ fm-playbot-lanes call list_parked_threads '{"landingBranches":{"FrogPile":"proto/godot/frog-pile"}}'
{
  "content": [
    {
      "type": "text",
      "text": "{\n  \"candidates\": [\n    {\n      \"id\": \"chat-ahead\",\n      \"title\": \"Hop animation\",\n      \"projectId\": \"project-frogpile\",\n      \"project\": \"FrogPile\",\n      \"workspaceId\": \"ws-ahead\",\n      \"workspace\": \"lane-ahead\",\n      \"sessionId\": \"sess-ahead\",\n      \"status\": \"pending_input\",\n      \"queuedCount\": 0,\n      \"hasUnread\": false,\n      \"isActive\": true,\n      \"archived\": false,\n      \"updatedAt\": \"2026-09-03T19:02:12.941Z\",\n      \"url\": \"playbot://workspace/ws-ahead/thread/chat-ahead\",\n      \"freshness\": {\n        \"workspace\": {\n          \"id\": \"ws-ahead\",\n          \"name\": \"lane-ahead\",\n          \"kind\": \"worktree\",\n          \"projectId\": \"project-frogpile\",\n          \"project\": \"FrogPile\"\n        },\n        \"landingBranch\": \"proto/godot/frog-pile\",\n        \"current\": true,\n        \"roots\": [\n          {\n            \"projectRootId\": \"root-frogpile\",\n            \"worktreePath\": \"<fixture>/frog-pile/.worktrees/ahead\",\n            \"head\": {\n              \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n              \"subject\": \"tune pile physics\"\n            },\n            \"landingBranch\": \"proto/godot/frog-pile\",\n            \"landingBranchTip\": {\n              \"requested\": \"proto/godot/frog-pile\",\n              \"remote\": \"origin\",\n              \"branch\": \"proto/godot/frog-pile\",\n              \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"observedAt\": \"2026-09-03T19:02:13.904Z\",\n              \"presentLocally\": true\n            },\n            \"relation\": \"ahead\",\n            \"distanceKnown\": true,\n            \"commitsAhead\": 2,\n            \"commitsBehind\": 0,\n            \"current\": true,\n            \"headIsCleanFastForwardOfLandingTip\": true,\n            \"unlandedCommits\": [\n              {\n                \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n                \"subject\": \"tune pile physics\"\n              },\n              {\n                \"commit\": \"820d172bc023a04c4e1d4b72036ae4bd8cf52c7f\",\n                \"subject\": \"add frog hop animation\"\n              }\n            ]\n          }\n        ]\n      }\n    },\n    {\n      \"id\": \"chat-partial\",\n      \"title\": \"Partial work\",\n      \"projectId\": \"project-partial\",\n      \"project\": \"partial-clone\",\n      \"workspaceId\": \"ws-partial\",\n      \"workspace\": \"partial\",\n      \"sessionId\": \"sess-partial\",\n      \"status\": \"pending_input\",\n      \"queuedCount\": 0,\n      \"hasUnread\": false,\n      \"isActive\": true,\n      \"archived\": false,\n      \"updatedAt\": \"2026-09-03T19:02:12.941Z\",\n      \"url\": \"playbot://workspace/ws-partial/thread/chat-partial\"\n    }\n  ],\n  \"confirmWith\": \"get_thread_card\",\n  \"note\": \"Persisted status only. Playbot reports a rehydrated chat as pending_input even when it is not parked, so confirm each candidate with get_thread_card before answering anything.\"\n}"
    }
  ],
  "structuredContent": {
    "candidates": [
      {
        "id": "chat-ahead",
        "title": "Hop animation",
        "projectId": "project-frogpile",
        "project": "FrogPile",
        "workspaceId": "ws-ahead",
        "workspace": "lane-ahead",
        "sessionId": "sess-ahead",
        "status": "pending_input",
        "queuedCount": 0,
        "hasUnread": false,
        "isActive": true,
        "archived": false,
        "updatedAt": "2026-09-03T19:02:12.941Z",
        "url": "playbot://workspace/ws-ahead/thread/chat-ahead",
        "freshness": {
          "workspace": {
            "id": "ws-ahead",
            "name": "lane-ahead",
            "kind": "worktree",
            "projectId": "project-frogpile",
            "project": "FrogPile"
          },
          "landingBranch": "proto/godot/frog-pile",
          "current": true,
          "roots": [
            {
              "projectRootId": "root-frogpile",
              "worktreePath": "<fixture>/frog-pile/.worktrees/ahead",
              "head": {
                "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
                "subject": "tune pile physics"
              },
              "landingBranch": "proto/godot/frog-pile",
              "landingBranchTip": {
                "requested": "proto/godot/frog-pile",
                "remote": "origin",
                "branch": "proto/godot/frog-pile",
                "remoteRef": "refs/heads/proto/godot/frog-pile",
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "observedAt": "2026-09-03T19:02:13.904Z",
                "presentLocally": true
              },
              "relation": "ahead",
              "distanceKnown": true,
              "commitsAhead": 2,
              "commitsBehind": 0,
              "current": true,
              "headIsCleanFastForwardOfLandingTip": true,
              "unlandedCommits": [
                {
                  "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
                  "subject": "tune pile physics"
                },
                {
                  "commit": "820d172bc023a04c4e1d4b72036ae4bd8cf52c7f",
                  "subject": "add frog hop animation"
                }
              ]
            }
          ]
        }
      },
      {
        "id": "chat-partial",
        "title": "Partial work",
        "projectId": "project-partial",
        "project": "partial-clone",
        "workspaceId": "ws-partial",
        "workspace": "partial",
        "sessionId": "sess-partial",
        "status": "pending_input",
        "queuedCount": 0,
        "hasUnread": false,
        "isActive": true,
        "archived": false,
        "updatedAt": "2026-09-03T19:02:12.941Z",
        "url": "playbot://workspace/ws-partial/thread/chat-partial"
      }
    ],
    "confirmWith": "get_thread_card",
    "note": "Persisted status only. Playbot reports a rehydrated chat as pending_input even when it is not parked, so confirm each candidate with get_thread_card before answering anything."
  }
}
```

## list_parked_threads: omitted project + single landingBranch is rejected

```
$ fm-playbot-lanes call list_parked_threads '{"landingBranch":"proto/godot/frog-pile"}'
list_parked_threads landingBranch is only valid with an explicit project; use landingBranches for global scope
```

## list_retirable_workspaces: shared freshness on every row; Local (Main) row is never retirable

```
$ fm-playbot-lanes call list_retirable_workspaces '{"project":"FrogPile","landingBranch":"proto/godot/frog-pile"}'
{
  "content": [
    {
      "type": "text",
      "text": "{\n  \"project\": {\n    \"id\": \"project-frogpile\",\n    \"name\": \"FrogPile\"\n  },\n  \"landingBranch\": \"proto/godot/frog-pile\",\n  \"trackedChurnAllowlist\": [\n    \"prototype-game/addons/playbot/playbot_common.gd.uid\",\n    \"prototype-game/addons/playbot/playbot_export_plugin.gd\",\n    \"prototype-game/addons/playbot/playbot_export_plugin.gd.uid\",\n    \"prototype-game/addons/playbot/playbot_log_capture.gd.source\",\n    \"prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid\",\n    \"prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid\",\n    \"prototype-game/addons/playbot/plugin.gd.uid\",\n    \"prototype-game/project.godot\"\n  ],\n  \"untrackedBoundary\": \"Untracked files are reported and block retirement; the tracked-churn allowlist never applies to them.\",\n  \"workspaces\": [\n    {\n      \"workspace\": {\n        \"id\": \"ws-ahead\",\n        \"name\": \"lane-ahead\",\n        \"kind\": \"worktree\",\n        \"selected\": false,\n        \"archiveState\": \"active\",\n        \"projectId\": \"project-frogpile\",\n        \"project\": \"FrogPile\"\n      },\n      \"landingBranch\": \"proto/godot/frog-pile\",\n      \"threads\": {\n        \"unarchived\": [\n          {\n            \"id\": \"chat-ahead\",\n            \"title\": \"Hop animation\",\n            \"status\": \"pending_input\",\n            \"updatedAt\": \"2026-09-03T19:02:12.941Z\"\n          }\n        ],\n        \"blocking\": [\n          {\n            \"id\": \"chat-ahead\",\n            \"title\": \"Hop animation\",\n            \"status\": \"pending_input\",\n            \"updatedAt\": \"2026-09-03T19:02:12.941Z\"\n          }\n        ],\n        \"uncertain\": []\n      },\n      \"roots\": [\n        {\n          \"projectRootId\": \"root-frogpile\",\n          \"path\": \"<fixture>/frog-pile/.worktrees/ahead\",\n          \"branch\": \"lane/ahead\",\n          \"head\": {\n            \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n            \"subject\": \"tune pile physics\"\n          },\n          \"landing\": {\n            \"requested\": \"proto/godot/frog-pile\",\n            \"remote\": \"origin\",\n            \"branch\": \"proto/godot/frog-pile\",\n            \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n            \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n            \"observedAt\": \"2026-09-03T19:02:14.048Z\",\n            \"presentLocally\": true\n          },\n          \"commitsAhead\": [\n            {\n              \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n              \"subject\": \"tune pile physics\"\n            },\n            {\n              \"commit\": \"820d172bc023a04c4e1d4b72036ae4bd8cf52c7f\",\n              \"subject\": \"add frog hop animation\"\n            }\n          ],\n          \"commitsBehind\": 0,\n          \"freshness\": {\n            \"projectRootId\": \"root-frogpile\",\n            \"worktreePath\": \"<fixture>/frog-pile/.worktrees/ahead\",\n            \"head\": {\n              \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n              \"subject\": \"tune pile physics\"\n            },\n            \"landingBranch\": \"proto/godot/frog-pile\",\n            \"landingBranchTip\": {\n              \"requested\": \"proto/godot/frog-pile\",\n              \"remote\": \"origin\",\n              \"branch\": \"proto/godot/frog-pile\",\n              \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"observedAt\": \"2026-09-03T19:02:14.048Z\",\n              \"presentLocally\": true\n            },\n            \"relation\": \"ahead\",\n            \"distanceKnown\": true,\n            \"commitsAhead\": 2,\n            \"commitsBehind\": 0,\n            \"current\": true,\n            \"headIsCleanFastForwardOfLandingTip\": true,\n            \"unlandedCommits\": [\n              {\n                \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n                \"subject\": \"tune pile physics\"\n              },\n              {\n                \"commit\": \"820d172bc023a04c4e1d4b72036ae4bd8cf52c7f\",\n                \"subject\": \"add frog hop animation\"\n              }\n            ]\n          },\n          \"tracked\": {\n            \"paths\": [],\n            \"allowedChurnPaths\": [],\n            \"blockingPaths\": [],\n            \"allowlist\": [\n              \"prototype-game/addons/playbot/playbot_common.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_export_plugin.gd\",\n              \"prototype-game/addons/playbot/playbot_export_plugin.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_log_capture.gd.source\",\n              \"prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid\",\n              \"prototype-game/addons/playbot/plugin.gd.uid\",\n              \"prototype-game/project.godot\"\n            ]\n          },\n          \"untrackedPaths\": [],\n          \"ignoredPaths\": [],\n          \"indexFlags\": [],\n          \"operations\": [],\n          \"submodules\": {\n            \"inspected\": [],\n            \"persisted\": [],\n            \"unreadable\": []\n          },\n          \"gitRegistration\": {\n            \"projectRootPath\": \"<fixture>/frog-pile\",\n            \"registered\": true\n          },\n          \"blockers\": [\n            {\n              \"code\": \"unlanded-commits\",\n              \"message\": \"2 commit(s) are ahead of proto/godot/frog-pile\",\n              \"commits\": [\n                {\n                  \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n                  \"subject\": \"tune pile physics\"\n                },\n                {\n                  \"commit\": \"820d172bc023a04c4e1d4b72036ae4bd8cf52c7f\",\n                  \"subject\": \"add frog hop animation\"\n                }\n              ]\n            }\n          ]\n        }\n      ],\n      \"blockers\": [\n        {\n          \"code\": \"active-threads\",\n          \"message\": \"1 unarchived chat(s) are working or pending input\",\n          \"threads\": [\n            {\n              \"id\": \"chat-ahead\",\n              \"title\": \"Hop animation\",\n              \"status\": \"pending_input\",\n              \"updatedAt\": \"2026-09-03T19:02:12.941Z\"\n            }\n          ]\n        },\n        {\n          \"code\": \"unlanded-commits\",\n          \"message\": \"2 commit(s) are ahead of proto/godot/frog-pile\",\n          \"commits\": [\n            {\n              \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n              \"subject\": \"tune pile physics\"\n            },\n            {\n              \"commit\": \"820d172bc023a04c4e1d4b72036ae4bd8cf52c7f\",\n              \"subject\": \"add frog hop animation\"\n            }\n          ]\n        }\n      ],\n      \"freshness\": {\n        \"workspace\": {\n          \"id\": \"ws-ahead\",\n          \"name\": \"lane-ahead\",\n          \"kind\": \"worktree\",\n          \"projectId\": \"project-frogpile\",\n          \"project\": \"FrogPile\"\n        },\n        \"landingBranch\": \"proto/godot/frog-pile\",\n        \"current\": true,\n        \"roots\": [\n          {\n            \"projectRootId\": \"root-frogpile\",\n            \"worktreePath\": \"<fixture>/frog-pile/.worktrees/ahead\",\n            \"head\": {\n              \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n              \"subject\": \"tune pile physics\"\n            },\n            \"landingBranch\": \"proto/godot/frog-pile\",\n            \"landingBranchTip\": {\n              \"requested\": \"proto/godot/frog-pile\",\n              \"remote\": \"origin\",\n              \"branch\": \"proto/godot/frog-pile\",\n              \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"observedAt\": \"2026-09-03T19:02:14.048Z\",\n              \"presentLocally\": true\n            },\n            \"relation\": \"ahead\",\n            \"distanceKnown\": true,\n            \"commitsAhead\": 2,\n            \"commitsBehind\": 0,\n            \"current\": true,\n            \"headIsCleanFastForwardOfLandingTip\": true,\n            \"unlandedCommits\": [\n              {\n                \"commit\": \"e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b\",\n                \"subject\": \"tune pile physics\"\n              },\n              {\n                \"commit\": \"820d172bc023a04c4e1d4b72036ae4bd8cf52c7f\",\n                \"subject\": \"add frog hop animation\"\n              }\n            ]\n          }\n        ]\n      },\n      \"retirable\": false,\n      \"verdict\": \"blocked\"\n    },\n    {\n      \"workspace\": {\n        \"id\": \"ws-behind\",\n        \"name\": \"lane-behind\",\n        \"kind\": \"worktree\",\n        \"selected\": false,\n        \"archiveState\": \"active\",\n        \"projectId\": \"project-frogpile\",\n        \"project\": \"FrogPile\"\n      },\n      \"landingBranch\": \"proto/godot/frog-pile\",\n      \"threads\": {\n        \"unarchived\": [],\n        \"blocking\": [],\n        \"uncertain\": []\n      },\n      \"roots\": [\n        {\n          \"projectRootId\": \"root-frogpile\",\n          \"path\": \"<fixture>/frog-pile/.worktrees/behind\",\n          \"branch\": \"lane/behind\",\n          \"head\": {\n            \"commit\": \"c7eef4a138acbcbe58f0f802ec62c73d6cfde419\",\n            \"subject\": \"frog-pile baseline\"\n          },\n          \"landing\": {\n            \"requested\": \"proto/godot/frog-pile\",\n            \"remote\": \"origin\",\n            \"branch\": \"proto/godot/frog-pile\",\n            \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n            \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n            \"observedAt\": \"2026-09-03T19:02:14.143Z\",\n            \"presentLocally\": true\n          },\n          \"commitsAhead\": [],\n          \"commitsBehind\": 1,\n          \"freshness\": {\n            \"projectRootId\": \"root-frogpile\",\n            \"worktreePath\": \"<fixture>/frog-pile/.worktrees/behind\",\n            \"head\": {\n              \"commit\": \"c7eef4a138acbcbe58f0f802ec62c73d6cfde419\",\n              \"subject\": \"frog-pile baseline\"\n            },\n            \"landingBranch\": \"proto/godot/frog-pile\",\n            \"landingBranchTip\": {\n              \"requested\": \"proto/godot/frog-pile\",\n              \"remote\": \"origin\",\n              \"branch\": \"proto/godot/frog-pile\",\n              \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"observedAt\": \"2026-09-03T19:02:14.143Z\",\n              \"presentLocally\": true\n            },\n            \"relation\": \"behind\",\n            \"distanceKnown\": true,\n            \"commitsAhead\": 0,\n            \"commitsBehind\": 1,\n            \"current\": false,\n            \"headIsCleanFastForwardOfLandingTip\": false,\n            \"unlandedCommits\": []\n          },\n          \"tracked\": {\n            \"paths\": [],\n            \"allowedChurnPaths\": [],\n            \"blockingPaths\": [],\n            \"allowlist\": [\n              \"prototype-game/addons/playbot/playbot_common.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_export_plugin.gd\",\n              \"prototype-game/addons/playbot/playbot_export_plugin.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_log_capture.gd.source\",\n              \"prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid\",\n              \"prototype-game/addons/playbot/plugin.gd.uid\",\n              \"prototype-game/project.godot\"\n            ]\n          },\n          \"untrackedPaths\": [],\n          \"ignoredPaths\": [],\n          \"indexFlags\": [],\n          \"operations\": [],\n          \"submodules\": {\n            \"inspected\": [],\n            \"persisted\": [],\n            \"unreadable\": []\n          },\n          \"gitRegistration\": {\n            \"projectRootPath\": \"<fixture>/frog-pile\",\n            \"registered\": true\n          },\n          \"blockers\": []\n        }\n      ],\n      \"blockers\": [],\n      \"freshness\": {\n        \"workspace\": {\n          \"id\": \"ws-behind\",\n          \"name\": \"lane-behind\",\n          \"kind\": \"worktree\",\n          \"projectId\": \"project-frogpile\",\n          \"project\": \"FrogPile\"\n        },\n        \"landingBranch\": \"proto/godot/frog-pile\",\n        \"current\": false,\n        \"roots\": [\n          {\n            \"projectRootId\": \"root-frogpile\",\n            \"worktreePath\": \"<fixture>/frog-pile/.worktrees/behind\",\n            \"head\": {\n              \"commit\": \"c7eef4a138acbcbe58f0f802ec62c73d6cfde419\",\n              \"subject\": \"frog-pile baseline\"\n            },\n            \"landingBranch\": \"proto/godot/frog-pile\",\n            \"landingBranchTip\": {\n              \"requested\": \"proto/godot/frog-pile\",\n              \"remote\": \"origin\",\n              \"branch\": \"proto/godot/frog-pile\",\n              \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"observedAt\": \"2026-09-03T19:02:14.143Z\",\n              \"presentLocally\": true\n            },\n            \"relation\": \"behind\",\n            \"distanceKnown\": true,\n            \"commitsAhead\": 0,\n            \"commitsBehind\": 1,\n            \"current\": false,\n            \"headIsCleanFastForwardOfLandingTip\": false,\n            \"unlandedCommits\": []\n          }\n        ]\n      },\n      \"retirable\": true,\n      \"verdict\": \"retirable\"\n    },\n    {\n      \"workspace\": {\n        \"id\": \"ws-clean\",\n        \"name\": \"lane-clean\",\n        \"kind\": \"worktree\",\n        \"selected\": false,\n        \"archiveState\": \"active\",\n        \"projectId\": \"project-frogpile\",\n        \"project\": \"FrogPile\"\n      },\n      \"landingBranch\": \"proto/godot/frog-pile\",\n      \"threads\": {\n        \"unarchived\": [],\n        \"blocking\": [],\n        \"uncertain\": []\n      },\n      \"roots\": [\n        {\n          \"projectRootId\": \"root-frogpile\",\n          \"path\": \"<fixture>/frog-pile/.worktrees/clean\",\n          \"branch\": \"lane/clean\",\n          \"head\": {\n            \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n            \"subject\": \"landing advance\"\n          },\n          \"landing\": {\n            \"requested\": \"proto/godot/frog-pile\",\n            \"remote\": \"origin\",\n            \"branch\": \"proto/godot/frog-pile\",\n            \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n            \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n            \"observedAt\": \"2026-09-03T19:02:14.230Z\",\n            \"presentLocally\": true\n          },\n          \"commitsAhead\": [],\n          \"commitsBehind\": 0,\n          \"freshness\": {\n            \"projectRootId\": \"root-frogpile\",\n            \"worktreePath\": \"<fixture>/frog-pile/.worktrees/clean\",\n            \"head\": {\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"subject\": \"landing advance\"\n            },\n            \"landingBranch\": \"proto/godot/frog-pile\",\n            \"landingBranchTip\": {\n              \"requested\": \"proto/godot/frog-pile\",\n              \"remote\": \"origin\",\n              \"branch\": \"proto/godot/frog-pile\",\n              \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"observedAt\": \"2026-09-03T19:02:14.230Z\",\n              \"presentLocally\": true\n            },\n            \"relation\": \"equal\",\n            \"distanceKnown\": true,\n            \"commitsAhead\": 0,\n            \"commitsBehind\": 0,\n            \"current\": true,\n            \"headIsCleanFastForwardOfLandingTip\": true,\n            \"unlandedCommits\": []\n          },\n          \"tracked\": {\n            \"paths\": [],\n            \"allowedChurnPaths\": [],\n            \"blockingPaths\": [],\n            \"allowlist\": [\n              \"prototype-game/addons/playbot/playbot_common.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_export_plugin.gd\",\n              \"prototype-game/addons/playbot/playbot_export_plugin.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_log_capture.gd.source\",\n              \"prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid\",\n              \"prototype-game/addons/playbot/plugin.gd.uid\",\n              \"prototype-game/project.godot\"\n            ]\n          },\n          \"untrackedPaths\": [],\n          \"ignoredPaths\": [],\n          \"indexFlags\": [],\n          \"operations\": [],\n          \"submodules\": {\n            \"inspected\": [],\n            \"persisted\": [],\n            \"unreadable\": []\n          },\n          \"gitRegistration\": {\n            \"projectRootPath\": \"<fixture>/frog-pile\",\n            \"registered\": true\n          },\n          \"blockers\": []\n        }\n      ],\n      \"blockers\": [],\n      \"freshness\": {\n        \"workspace\": {\n          \"id\": \"ws-clean\",\n          \"name\": \"lane-clean\",\n          \"kind\": \"worktree\",\n          \"projectId\": \"project-frogpile\",\n          \"project\": \"FrogPile\"\n        },\n        \"landingBranch\": \"proto/godot/frog-pile\",\n        \"current\": true,\n        \"roots\": [\n          {\n            \"projectRootId\": \"root-frogpile\",\n            \"worktreePath\": \"<fixture>/frog-pile/.worktrees/clean\",\n            \"head\": {\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"subject\": \"landing advance\"\n            },\n            \"landingBranch\": \"proto/godot/frog-pile\",\n            \"landingBranchTip\": {\n              \"requested\": \"proto/godot/frog-pile\",\n              \"remote\": \"origin\",\n              \"branch\": \"proto/godot/frog-pile\",\n              \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"observedAt\": \"2026-09-03T19:02:14.230Z\",\n              \"presentLocally\": true\n            },\n            \"relation\": \"equal\",\n            \"distanceKnown\": true,\n            \"commitsAhead\": 0,\n            \"commitsBehind\": 0,\n            \"current\": true,\n            \"headIsCleanFastForwardOfLandingTip\": true,\n            \"unlandedCommits\": []\n          }\n        ]\n      },\n      \"retirable\": true,\n      \"verdict\": \"retirable\"\n    },\n    {\n      \"workspace\": {\n        \"id\": \"ws-diverged\",\n        \"name\": \"lane-diverged\",\n        \"kind\": \"worktree\",\n        \"selected\": false,\n        \"archiveState\": \"active\",\n        \"projectId\": \"project-frogpile\",\n        \"project\": \"FrogPile\"\n      },\n      \"landingBranch\": \"proto/godot/frog-pile\",\n      \"threads\": {\n        \"unarchived\": [],\n        \"blocking\": [],\n        \"uncertain\": []\n      },\n      \"roots\": [\n        {\n          \"projectRootId\": \"root-frogpile\",\n          \"path\": \"<fixture>/frog-pile/.worktrees/diverged\",\n          \"branch\": \"lane/diverged\",\n          \"head\": {\n            \"commit\": \"07b072b6dcdf07a37a91b8dd6395f75876f0aff8\",\n            \"subject\": \"diverged lane work\"\n          },\n          \"landing\": {\n            \"requested\": \"proto/godot/frog-pile\",\n            \"remote\": \"origin\",\n            \"branch\": \"proto/godot/frog-pile\",\n            \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n            \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n            \"observedAt\": \"2026-09-03T19:02:14.317Z\",\n            \"presentLocally\": true\n          },\n          \"commitsAhead\": [\n            {\n              \"commit\": \"07b072b6dcdf07a37a91b8dd6395f75876f0aff8\",\n              \"subject\": \"diverged lane work\"\n            }\n          ],\n          \"commitsBehind\": 1,\n          \"freshness\": {\n            \"projectRootId\": \"root-frogpile\",\n            \"worktreePath\": \"<fixture>/frog-pile/.worktrees/diverged\",\n            \"head\": {\n              \"commit\": \"07b072b6dcdf07a37a91b8dd6395f75876f0aff8\",\n              \"subject\": \"diverged lane work\"\n            },\n            \"landingBranch\": \"proto/godot/frog-pile\",\n            \"landingBranchTip\": {\n              \"requested\": \"proto/godot/frog-pile\",\n              \"remote\": \"origin\",\n              \"branch\": \"proto/godot/frog-pile\",\n              \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"observedAt\": \"2026-09-03T19:02:14.317Z\",\n              \"presentLocally\": true\n            },\n            \"relation\": \"diverged\",\n            \"distanceKnown\": true,\n            \"commitsAhead\": 1,\n            \"commitsBehind\": 1,\n            \"current\": false,\n            \"headIsCleanFastForwardOfLandingTip\": false,\n            \"unlandedCommits\": [\n              {\n                \"commit\": \"07b072b6dcdf07a37a91b8dd6395f75876f0aff8\",\n                \"subject\": \"diverged lane work\"\n              }\n            ]\n          },\n          \"tracked\": {\n            \"paths\": [],\n            \"allowedChurnPaths\": [],\n            \"blockingPaths\": [],\n            \"allowlist\": [\n              \"prototype-game/addons/playbot/playbot_common.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_export_plugin.gd\",\n              \"prototype-game/addons/playbot/playbot_export_plugin.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_log_capture.gd.source\",\n              \"prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid\",\n              \"prototype-game/addons/playbot/plugin.gd.uid\",\n              \"prototype-game/project.godot\"\n            ]\n          },\n          \"untrackedPaths\": [],\n          \"ignoredPaths\": [],\n          \"indexFlags\": [],\n          \"operations\": [],\n          \"submodules\": {\n            \"inspected\": [],\n            \"persisted\": [],\n            \"unreadable\": []\n          },\n          \"gitRegistration\": {\n            \"projectRootPath\": \"<fixture>/frog-pile\",\n            \"registered\": true\n          },\n          \"blockers\": [\n            {\n              \"code\": \"unlanded-commits\",\n              \"message\": \"1 commit(s) are ahead of proto/godot/frog-pile\",\n              \"commits\": [\n                {\n                  \"commit\": \"07b072b6dcdf07a37a91b8dd6395f75876f0aff8\",\n                  \"subject\": \"diverged lane work\"\n                }\n              ]\n            }\n          ]\n        }\n      ],\n      \"blockers\": [\n        {\n          \"code\": \"unlanded-commits\",\n          \"message\": \"1 commit(s) are ahead of proto/godot/frog-pile\",\n          \"commits\": [\n            {\n              \"commit\": \"07b072b6dcdf07a37a91b8dd6395f75876f0aff8\",\n              \"subject\": \"diverged lane work\"\n            }\n          ]\n        }\n      ],\n      \"freshness\": {\n        \"workspace\": {\n          \"id\": \"ws-diverged\",\n          \"name\": \"lane-diverged\",\n          \"kind\": \"worktree\",\n          \"projectId\": \"project-frogpile\",\n          \"project\": \"FrogPile\"\n        },\n        \"landingBranch\": \"proto/godot/frog-pile\",\n        \"current\": false,\n        \"roots\": [\n          {\n            \"projectRootId\": \"root-frogpile\",\n            \"worktreePath\": \"<fixture>/frog-pile/.worktrees/diverged\",\n            \"head\": {\n              \"commit\": \"07b072b6dcdf07a37a91b8dd6395f75876f0aff8\",\n              \"subject\": \"diverged lane work\"\n            },\n            \"landingBranch\": \"proto/godot/frog-pile\",\n            \"landingBranchTip\": {\n              \"requested\": \"proto/godot/frog-pile\",\n              \"remote\": \"origin\",\n              \"branch\": \"proto/godot/frog-pile\",\n              \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"observedAt\": \"2026-09-03T19:02:14.317Z\",\n              \"presentLocally\": true\n            },\n            \"relation\": \"diverged\",\n            \"distanceKnown\": true,\n            \"commitsAhead\": 1,\n            \"commitsBehind\": 1,\n            \"current\": false,\n            \"headIsCleanFastForwardOfLandingTip\": false,\n            \"unlandedCommits\": [\n              {\n                \"commit\": \"07b072b6dcdf07a37a91b8dd6395f75876f0aff8\",\n                \"subject\": \"diverged lane work\"\n              }\n            ]\n          }\n        ]\n      },\n      \"retirable\": false,\n      \"verdict\": \"blocked\"\n    },\n    {\n      \"workspace\": {\n        \"id\": \"ws-frogpile-main\",\n        \"name\": \"Main\",\n        \"kind\": \"local\",\n        \"selected\": true,\n        \"archiveState\": \"active\",\n        \"projectId\": \"project-frogpile\",\n        \"project\": \"FrogPile\"\n      },\n      \"landingBranch\": \"proto/godot/frog-pile\",\n      \"threads\": {\n        \"unarchived\": [],\n        \"blocking\": [],\n        \"uncertain\": []\n      },\n      \"roots\": [\n        {\n          \"projectRootId\": \"root-frogpile\",\n          \"path\": \"<fixture>/frog-pile\",\n          \"branch\": \"proto/godot/frog-pile\",\n          \"inspection\": \"skipped because Local workspaces are never retirable\"\n        }\n      ],\n      \"blockers\": [\n        {\n          \"code\": \"local-workspace\",\n          \"message\": \"Local workspaces are never retirable\"\n        }\n      ],\n      \"freshness\": {\n        \"workspace\": {\n          \"id\": \"ws-frogpile-main\",\n          \"name\": \"Main\",\n          \"kind\": \"local\",\n          \"projectId\": \"project-frogpile\",\n          \"project\": \"FrogPile\"\n        },\n        \"landingBranch\": \"proto/godot/frog-pile\",\n        \"current\": true,\n        \"roots\": [\n          {\n            \"projectRootId\": \"root-frogpile\",\n            \"worktreePath\": \"<fixture>/frog-pile\",\n            \"head\": {\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"subject\": \"landing advance\"\n            },\n            \"landingBranch\": \"proto/godot/frog-pile\",\n            \"landingBranchTip\": {\n              \"requested\": \"proto/godot/frog-pile\",\n              \"remote\": \"origin\",\n              \"branch\": \"proto/godot/frog-pile\",\n              \"remoteRef\": \"refs/heads/proto/godot/frog-pile\",\n              \"commit\": \"14727fb18bfa652e5717b3bf128f64adfeaeb126\",\n              \"observedAt\": \"2026-09-03T19:02:14.402Z\",\n              \"presentLocally\": true\n            },\n            \"relation\": \"equal\",\n            \"distanceKnown\": true,\n            \"commitsAhead\": 0,\n            \"commitsBehind\": 0,\n            \"current\": true,\n            \"headIsCleanFastForwardOfLandingTip\": true,\n            \"unlandedCommits\": []\n          }\n        ]\n      },\n      \"retirable\": false,\n      \"verdict\": \"blocked\"\n    },\n    {\n      \"workspace\": {\n        \"id\": \"ws-missing\",\n        \"name\": \"lane-missing\",\n        \"kind\": \"worktree\",\n        \"selected\": false,\n        \"archiveState\": \"active\",\n        \"projectId\": \"project-frogpile\",\n        \"project\": \"FrogPile\"\n      },\n      \"landingBranch\": \"proto/godot/frog-pile\",\n      \"threads\": {\n        \"unarchived\": [],\n        \"blocking\": [],\n        \"uncertain\": []\n      },\n      \"roots\": [\n        {\n          \"projectRootId\": \"root-frogpile\",\n          \"path\": \"<fixture>/frog-pile/.worktrees/missing\",\n          \"branch\": \"lane/missing\",\n          \"head\": null,\n          \"landing\": null,\n          \"commitsAhead\": [],\n          \"commitsBehind\": null,\n          \"freshness\": null,\n          \"tracked\": {\n            \"paths\": [],\n            \"allowedChurnPaths\": [],\n            \"blockingPaths\": [],\n            \"allowlist\": [\n              \"prototype-game/addons/playbot/playbot_common.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_export_plugin.gd\",\n              \"prototype-game/addons/playbot/playbot_export_plugin.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_log_capture.gd.source\",\n              \"prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid\",\n              \"prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid\",\n              \"prototype-game/addons/playbot/plugin.gd.uid\",\n              \"prototype-game/project.godot\"\n            ]\n          },\n          \"untrackedPaths\": [],\n          \"ignoredPaths\": [],\n          \"indexFlags\": [],\n          \"operations\": [],\n          \"submodules\": {\n            \"inspected\": [],\n            \"persisted\": [],\n            \"unreadable\": []\n          },\n          \"gitRegistration\": null,\n          \"blockers\": [\n            {\n              \"code\": \"missing-root\",\n              \"message\": \"Workspace root is missing: <fixture>/frog-pile/.worktrees/missing\"\n            }\n          ]\n        }\n      ],\n      \"blockers\": [\n        {\n          \"code\": \"missing-root\",\n          \"message\": \"Workspace root is missing: <fixture>/frog-pile/.worktrees/missing\"\n        }\n      ],\n      \"freshness\": null,\n      \"retirable\": false,\n      \"verdict\": \"blocked\"\n    }\n  ]\n}"
    }
  ],
  "structuredContent": {
    "project": {
      "id": "project-frogpile",
      "name": "FrogPile"
    },
    "landingBranch": "proto/godot/frog-pile",
    "trackedChurnAllowlist": [
      "prototype-game/addons/playbot/playbot_common.gd.uid",
      "prototype-game/addons/playbot/playbot_export_plugin.gd",
      "prototype-game/addons/playbot/playbot_export_plugin.gd.uid",
      "prototype-game/addons/playbot/playbot_log_capture.gd.source",
      "prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid",
      "prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid",
      "prototype-game/addons/playbot/plugin.gd.uid",
      "prototype-game/project.godot"
    ],
    "untrackedBoundary": "Untracked files are reported and block retirement; the tracked-churn allowlist never applies to them.",
    "workspaces": [
      {
        "workspace": {
          "id": "ws-ahead",
          "name": "lane-ahead",
          "kind": "worktree",
          "selected": false,
          "archiveState": "active",
          "projectId": "project-frogpile",
          "project": "FrogPile"
        },
        "landingBranch": "proto/godot/frog-pile",
        "threads": {
          "unarchived": [
            {
              "id": "chat-ahead",
              "title": "Hop animation",
              "status": "pending_input",
              "updatedAt": "2026-09-03T19:02:12.941Z"
            }
          ],
          "blocking": [
            {
              "id": "chat-ahead",
              "title": "Hop animation",
              "status": "pending_input",
              "updatedAt": "2026-09-03T19:02:12.941Z"
            }
          ],
          "uncertain": []
        },
        "roots": [
          {
            "projectRootId": "root-frogpile",
            "path": "<fixture>/frog-pile/.worktrees/ahead",
            "branch": "lane/ahead",
            "head": {
              "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
              "subject": "tune pile physics"
            },
            "landing": {
              "requested": "proto/godot/frog-pile",
              "remote": "origin",
              "branch": "proto/godot/frog-pile",
              "remoteRef": "refs/heads/proto/godot/frog-pile",
              "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
              "observedAt": "2026-09-03T19:02:14.048Z",
              "presentLocally": true
            },
            "commitsAhead": [
              {
                "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
                "subject": "tune pile physics"
              },
              {
                "commit": "820d172bc023a04c4e1d4b72036ae4bd8cf52c7f",
                "subject": "add frog hop animation"
              }
            ],
            "commitsBehind": 0,
            "freshness": {
              "projectRootId": "root-frogpile",
              "worktreePath": "<fixture>/frog-pile/.worktrees/ahead",
              "head": {
                "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
                "subject": "tune pile physics"
              },
              "landingBranch": "proto/godot/frog-pile",
              "landingBranchTip": {
                "requested": "proto/godot/frog-pile",
                "remote": "origin",
                "branch": "proto/godot/frog-pile",
                "remoteRef": "refs/heads/proto/godot/frog-pile",
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "observedAt": "2026-09-03T19:02:14.048Z",
                "presentLocally": true
              },
              "relation": "ahead",
              "distanceKnown": true,
              "commitsAhead": 2,
              "commitsBehind": 0,
              "current": true,
              "headIsCleanFastForwardOfLandingTip": true,
              "unlandedCommits": [
                {
                  "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
                  "subject": "tune pile physics"
                },
                {
                  "commit": "820d172bc023a04c4e1d4b72036ae4bd8cf52c7f",
                  "subject": "add frog hop animation"
                }
              ]
            },
            "tracked": {
              "paths": [],
              "allowedChurnPaths": [],
              "blockingPaths": [],
              "allowlist": [
                "prototype-game/addons/playbot/playbot_common.gd.uid",
                "prototype-game/addons/playbot/playbot_export_plugin.gd",
                "prototype-game/addons/playbot/playbot_export_plugin.gd.uid",
                "prototype-game/addons/playbot/playbot_log_capture.gd.source",
                "prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid",
                "prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid",
                "prototype-game/addons/playbot/plugin.gd.uid",
                "prototype-game/project.godot"
              ]
            },
            "untrackedPaths": [],
            "ignoredPaths": [],
            "indexFlags": [],
            "operations": [],
            "submodules": {
              "inspected": [],
              "persisted": [],
              "unreadable": []
            },
            "gitRegistration": {
              "projectRootPath": "<fixture>/frog-pile",
              "registered": true
            },
            "blockers": [
              {
                "code": "unlanded-commits",
                "message": "2 commit(s) are ahead of proto/godot/frog-pile",
                "commits": [
                  {
                    "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
                    "subject": "tune pile physics"
                  },
                  {
                    "commit": "820d172bc023a04c4e1d4b72036ae4bd8cf52c7f",
                    "subject": "add frog hop animation"
                  }
                ]
              }
            ]
          }
        ],
        "blockers": [
          {
            "code": "active-threads",
            "message": "1 unarchived chat(s) are working or pending input",
            "threads": [
              {
                "id": "chat-ahead",
                "title": "Hop animation",
                "status": "pending_input",
                "updatedAt": "2026-09-03T19:02:12.941Z"
              }
            ]
          },
          {
            "code": "unlanded-commits",
            "message": "2 commit(s) are ahead of proto/godot/frog-pile",
            "commits": [
              {
                "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
                "subject": "tune pile physics"
              },
              {
                "commit": "820d172bc023a04c4e1d4b72036ae4bd8cf52c7f",
                "subject": "add frog hop animation"
              }
            ]
          }
        ],
        "freshness": {
          "workspace": {
            "id": "ws-ahead",
            "name": "lane-ahead",
            "kind": "worktree",
            "projectId": "project-frogpile",
            "project": "FrogPile"
          },
          "landingBranch": "proto/godot/frog-pile",
          "current": true,
          "roots": [
            {
              "projectRootId": "root-frogpile",
              "worktreePath": "<fixture>/frog-pile/.worktrees/ahead",
              "head": {
                "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
                "subject": "tune pile physics"
              },
              "landingBranch": "proto/godot/frog-pile",
              "landingBranchTip": {
                "requested": "proto/godot/frog-pile",
                "remote": "origin",
                "branch": "proto/godot/frog-pile",
                "remoteRef": "refs/heads/proto/godot/frog-pile",
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "observedAt": "2026-09-03T19:02:14.048Z",
                "presentLocally": true
              },
              "relation": "ahead",
              "distanceKnown": true,
              "commitsAhead": 2,
              "commitsBehind": 0,
              "current": true,
              "headIsCleanFastForwardOfLandingTip": true,
              "unlandedCommits": [
                {
                  "commit": "e5a333598ec39e2ad8ed59e1dc3faff3b7e3192b",
                  "subject": "tune pile physics"
                },
                {
                  "commit": "820d172bc023a04c4e1d4b72036ae4bd8cf52c7f",
                  "subject": "add frog hop animation"
                }
              ]
            }
          ]
        },
        "retirable": false,
        "verdict": "blocked"
      },
      {
        "workspace": {
          "id": "ws-behind",
          "name": "lane-behind",
          "kind": "worktree",
          "selected": false,
          "archiveState": "active",
          "projectId": "project-frogpile",
          "project": "FrogPile"
        },
        "landingBranch": "proto/godot/frog-pile",
        "threads": {
          "unarchived": [],
          "blocking": [],
          "uncertain": []
        },
        "roots": [
          {
            "projectRootId": "root-frogpile",
            "path": "<fixture>/frog-pile/.worktrees/behind",
            "branch": "lane/behind",
            "head": {
              "commit": "c7eef4a138acbcbe58f0f802ec62c73d6cfde419",
              "subject": "frog-pile baseline"
            },
            "landing": {
              "requested": "proto/godot/frog-pile",
              "remote": "origin",
              "branch": "proto/godot/frog-pile",
              "remoteRef": "refs/heads/proto/godot/frog-pile",
              "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
              "observedAt": "2026-09-03T19:02:14.143Z",
              "presentLocally": true
            },
            "commitsAhead": [],
            "commitsBehind": 1,
            "freshness": {
              "projectRootId": "root-frogpile",
              "worktreePath": "<fixture>/frog-pile/.worktrees/behind",
              "head": {
                "commit": "c7eef4a138acbcbe58f0f802ec62c73d6cfde419",
                "subject": "frog-pile baseline"
              },
              "landingBranch": "proto/godot/frog-pile",
              "landingBranchTip": {
                "requested": "proto/godot/frog-pile",
                "remote": "origin",
                "branch": "proto/godot/frog-pile",
                "remoteRef": "refs/heads/proto/godot/frog-pile",
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "observedAt": "2026-09-03T19:02:14.143Z",
                "presentLocally": true
              },
              "relation": "behind",
              "distanceKnown": true,
              "commitsAhead": 0,
              "commitsBehind": 1,
              "current": false,
              "headIsCleanFastForwardOfLandingTip": false,
              "unlandedCommits": []
            },
            "tracked": {
              "paths": [],
              "allowedChurnPaths": [],
              "blockingPaths": [],
              "allowlist": [
                "prototype-game/addons/playbot/playbot_common.gd.uid",
                "prototype-game/addons/playbot/playbot_export_plugin.gd",
                "prototype-game/addons/playbot/playbot_export_plugin.gd.uid",
                "prototype-game/addons/playbot/playbot_log_capture.gd.source",
                "prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid",
                "prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid",
                "prototype-game/addons/playbot/plugin.gd.uid",
                "prototype-game/project.godot"
              ]
            },
            "untrackedPaths": [],
            "ignoredPaths": [],
            "indexFlags": [],
            "operations": [],
            "submodules": {
              "inspected": [],
              "persisted": [],
              "unreadable": []
            },
            "gitRegistration": {
              "projectRootPath": "<fixture>/frog-pile",
              "registered": true
            },
            "blockers": []
          }
        ],
        "blockers": [],
        "freshness": {
          "workspace": {
            "id": "ws-behind",
            "name": "lane-behind",
            "kind": "worktree",
            "projectId": "project-frogpile",
            "project": "FrogPile"
          },
          "landingBranch": "proto/godot/frog-pile",
          "current": false,
          "roots": [
            {
              "projectRootId": "root-frogpile",
              "worktreePath": "<fixture>/frog-pile/.worktrees/behind",
              "head": {
                "commit": "c7eef4a138acbcbe58f0f802ec62c73d6cfde419",
                "subject": "frog-pile baseline"
              },
              "landingBranch": "proto/godot/frog-pile",
              "landingBranchTip": {
                "requested": "proto/godot/frog-pile",
                "remote": "origin",
                "branch": "proto/godot/frog-pile",
                "remoteRef": "refs/heads/proto/godot/frog-pile",
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "observedAt": "2026-09-03T19:02:14.143Z",
                "presentLocally": true
              },
              "relation": "behind",
              "distanceKnown": true,
              "commitsAhead": 0,
              "commitsBehind": 1,
              "current": false,
              "headIsCleanFastForwardOfLandingTip": false,
              "unlandedCommits": []
            }
          ]
        },
        "retirable": true,
        "verdict": "retirable"
      },
      {
        "workspace": {
          "id": "ws-clean",
          "name": "lane-clean",
          "kind": "worktree",
          "selected": false,
          "archiveState": "active",
          "projectId": "project-frogpile",
          "project": "FrogPile"
        },
        "landingBranch": "proto/godot/frog-pile",
        "threads": {
          "unarchived": [],
          "blocking": [],
          "uncertain": []
        },
        "roots": [
          {
            "projectRootId": "root-frogpile",
            "path": "<fixture>/frog-pile/.worktrees/clean",
            "branch": "lane/clean",
            "head": {
              "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
              "subject": "landing advance"
            },
            "landing": {
              "requested": "proto/godot/frog-pile",
              "remote": "origin",
              "branch": "proto/godot/frog-pile",
              "remoteRef": "refs/heads/proto/godot/frog-pile",
              "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
              "observedAt": "2026-09-03T19:02:14.230Z",
              "presentLocally": true
            },
            "commitsAhead": [],
            "commitsBehind": 0,
            "freshness": {
              "projectRootId": "root-frogpile",
              "worktreePath": "<fixture>/frog-pile/.worktrees/clean",
              "head": {
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "subject": "landing advance"
              },
              "landingBranch": "proto/godot/frog-pile",
              "landingBranchTip": {
                "requested": "proto/godot/frog-pile",
                "remote": "origin",
                "branch": "proto/godot/frog-pile",
                "remoteRef": "refs/heads/proto/godot/frog-pile",
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "observedAt": "2026-09-03T19:02:14.230Z",
                "presentLocally": true
              },
              "relation": "equal",
              "distanceKnown": true,
              "commitsAhead": 0,
              "commitsBehind": 0,
              "current": true,
              "headIsCleanFastForwardOfLandingTip": true,
              "unlandedCommits": []
            },
            "tracked": {
              "paths": [],
              "allowedChurnPaths": [],
              "blockingPaths": [],
              "allowlist": [
                "prototype-game/addons/playbot/playbot_common.gd.uid",
                "prototype-game/addons/playbot/playbot_export_plugin.gd",
                "prototype-game/addons/playbot/playbot_export_plugin.gd.uid",
                "prototype-game/addons/playbot/playbot_log_capture.gd.source",
                "prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid",
                "prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid",
                "prototype-game/addons/playbot/plugin.gd.uid",
                "prototype-game/project.godot"
              ]
            },
            "untrackedPaths": [],
            "ignoredPaths": [],
            "indexFlags": [],
            "operations": [],
            "submodules": {
              "inspected": [],
              "persisted": [],
              "unreadable": []
            },
            "gitRegistration": {
              "projectRootPath": "<fixture>/frog-pile",
              "registered": true
            },
            "blockers": []
          }
        ],
        "blockers": [],
        "freshness": {
          "workspace": {
            "id": "ws-clean",
            "name": "lane-clean",
            "kind": "worktree",
            "projectId": "project-frogpile",
            "project": "FrogPile"
          },
          "landingBranch": "proto/godot/frog-pile",
          "current": true,
          "roots": [
            {
              "projectRootId": "root-frogpile",
              "worktreePath": "<fixture>/frog-pile/.worktrees/clean",
              "head": {
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "subject": "landing advance"
              },
              "landingBranch": "proto/godot/frog-pile",
              "landingBranchTip": {
                "requested": "proto/godot/frog-pile",
                "remote": "origin",
                "branch": "proto/godot/frog-pile",
                "remoteRef": "refs/heads/proto/godot/frog-pile",
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "observedAt": "2026-09-03T19:02:14.230Z",
                "presentLocally": true
              },
              "relation": "equal",
              "distanceKnown": true,
              "commitsAhead": 0,
              "commitsBehind": 0,
              "current": true,
              "headIsCleanFastForwardOfLandingTip": true,
              "unlandedCommits": []
            }
          ]
        },
        "retirable": true,
        "verdict": "retirable"
      },
      {
        "workspace": {
          "id": "ws-diverged",
          "name": "lane-diverged",
          "kind": "worktree",
          "selected": false,
          "archiveState": "active",
          "projectId": "project-frogpile",
          "project": "FrogPile"
        },
        "landingBranch": "proto/godot/frog-pile",
        "threads": {
          "unarchived": [],
          "blocking": [],
          "uncertain": []
        },
        "roots": [
          {
            "projectRootId": "root-frogpile",
            "path": "<fixture>/frog-pile/.worktrees/diverged",
            "branch": "lane/diverged",
            "head": {
              "commit": "07b072b6dcdf07a37a91b8dd6395f75876f0aff8",
              "subject": "diverged lane work"
            },
            "landing": {
              "requested": "proto/godot/frog-pile",
              "remote": "origin",
              "branch": "proto/godot/frog-pile",
              "remoteRef": "refs/heads/proto/godot/frog-pile",
              "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
              "observedAt": "2026-09-03T19:02:14.317Z",
              "presentLocally": true
            },
            "commitsAhead": [
              {
                "commit": "07b072b6dcdf07a37a91b8dd6395f75876f0aff8",
                "subject": "diverged lane work"
              }
            ],
            "commitsBehind": 1,
            "freshness": {
              "projectRootId": "root-frogpile",
              "worktreePath": "<fixture>/frog-pile/.worktrees/diverged",
              "head": {
                "commit": "07b072b6dcdf07a37a91b8dd6395f75876f0aff8",
                "subject": "diverged lane work"
              },
              "landingBranch": "proto/godot/frog-pile",
              "landingBranchTip": {
                "requested": "proto/godot/frog-pile",
                "remote": "origin",
                "branch": "proto/godot/frog-pile",
                "remoteRef": "refs/heads/proto/godot/frog-pile",
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "observedAt": "2026-09-03T19:02:14.317Z",
                "presentLocally": true
              },
              "relation": "diverged",
              "distanceKnown": true,
              "commitsAhead": 1,
              "commitsBehind": 1,
              "current": false,
              "headIsCleanFastForwardOfLandingTip": false,
              "unlandedCommits": [
                {
                  "commit": "07b072b6dcdf07a37a91b8dd6395f75876f0aff8",
                  "subject": "diverged lane work"
                }
              ]
            },
            "tracked": {
              "paths": [],
              "allowedChurnPaths": [],
              "blockingPaths": [],
              "allowlist": [
                "prototype-game/addons/playbot/playbot_common.gd.uid",
                "prototype-game/addons/playbot/playbot_export_plugin.gd",
                "prototype-game/addons/playbot/playbot_export_plugin.gd.uid",
                "prototype-game/addons/playbot/playbot_log_capture.gd.source",
                "prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid",
                "prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid",
                "prototype-game/addons/playbot/plugin.gd.uid",
                "prototype-game/project.godot"
              ]
            },
            "untrackedPaths": [],
            "ignoredPaths": [],
            "indexFlags": [],
            "operations": [],
            "submodules": {
              "inspected": [],
              "persisted": [],
              "unreadable": []
            },
            "gitRegistration": {
              "projectRootPath": "<fixture>/frog-pile",
              "registered": true
            },
            "blockers": [
              {
                "code": "unlanded-commits",
                "message": "1 commit(s) are ahead of proto/godot/frog-pile",
                "commits": [
                  {
                    "commit": "07b072b6dcdf07a37a91b8dd6395f75876f0aff8",
                    "subject": "diverged lane work"
                  }
                ]
              }
            ]
          }
        ],
        "blockers": [
          {
            "code": "unlanded-commits",
            "message": "1 commit(s) are ahead of proto/godot/frog-pile",
            "commits": [
              {
                "commit": "07b072b6dcdf07a37a91b8dd6395f75876f0aff8",
                "subject": "diverged lane work"
              }
            ]
          }
        ],
        "freshness": {
          "workspace": {
            "id": "ws-diverged",
            "name": "lane-diverged",
            "kind": "worktree",
            "projectId": "project-frogpile",
            "project": "FrogPile"
          },
          "landingBranch": "proto/godot/frog-pile",
          "current": false,
          "roots": [
            {
              "projectRootId": "root-frogpile",
              "worktreePath": "<fixture>/frog-pile/.worktrees/diverged",
              "head": {
                "commit": "07b072b6dcdf07a37a91b8dd6395f75876f0aff8",
                "subject": "diverged lane work"
              },
              "landingBranch": "proto/godot/frog-pile",
              "landingBranchTip": {
                "requested": "proto/godot/frog-pile",
                "remote": "origin",
                "branch": "proto/godot/frog-pile",
                "remoteRef": "refs/heads/proto/godot/frog-pile",
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "observedAt": "2026-09-03T19:02:14.317Z",
                "presentLocally": true
              },
              "relation": "diverged",
              "distanceKnown": true,
              "commitsAhead": 1,
              "commitsBehind": 1,
              "current": false,
              "headIsCleanFastForwardOfLandingTip": false,
              "unlandedCommits": [
                {
                  "commit": "07b072b6dcdf07a37a91b8dd6395f75876f0aff8",
                  "subject": "diverged lane work"
                }
              ]
            }
          ]
        },
        "retirable": false,
        "verdict": "blocked"
      },
      {
        "workspace": {
          "id": "ws-frogpile-main",
          "name": "Main",
          "kind": "local",
          "selected": true,
          "archiveState": "active",
          "projectId": "project-frogpile",
          "project": "FrogPile"
        },
        "landingBranch": "proto/godot/frog-pile",
        "threads": {
          "unarchived": [],
          "blocking": [],
          "uncertain": []
        },
        "roots": [
          {
            "projectRootId": "root-frogpile",
            "path": "<fixture>/frog-pile",
            "branch": "proto/godot/frog-pile",
            "inspection": "skipped because Local workspaces are never retirable"
          }
        ],
        "blockers": [
          {
            "code": "local-workspace",
            "message": "Local workspaces are never retirable"
          }
        ],
        "freshness": {
          "workspace": {
            "id": "ws-frogpile-main",
            "name": "Main",
            "kind": "local",
            "projectId": "project-frogpile",
            "project": "FrogPile"
          },
          "landingBranch": "proto/godot/frog-pile",
          "current": true,
          "roots": [
            {
              "projectRootId": "root-frogpile",
              "worktreePath": "<fixture>/frog-pile",
              "head": {
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "subject": "landing advance"
              },
              "landingBranch": "proto/godot/frog-pile",
              "landingBranchTip": {
                "requested": "proto/godot/frog-pile",
                "remote": "origin",
                "branch": "proto/godot/frog-pile",
                "remoteRef": "refs/heads/proto/godot/frog-pile",
                "commit": "14727fb18bfa652e5717b3bf128f64adfeaeb126",
                "observedAt": "2026-09-03T19:02:14.402Z",
                "presentLocally": true
              },
              "relation": "equal",
              "distanceKnown": true,
              "commitsAhead": 0,
              "commitsBehind": 0,
              "current": true,
              "headIsCleanFastForwardOfLandingTip": true,
              "unlandedCommits": []
            }
          ]
        },
        "retirable": false,
        "verdict": "blocked"
      },
      {
        "workspace": {
          "id": "ws-missing",
          "name": "lane-missing",
          "kind": "worktree",
          "selected": false,
          "archiveState": "active",
          "projectId": "project-frogpile",
          "project": "FrogPile"
        },
        "landingBranch": "proto/godot/frog-pile",
        "threads": {
          "unarchived": [],
          "blocking": [],
          "uncertain": []
        },
        "roots": [
          {
            "projectRootId": "root-frogpile",
            "path": "<fixture>/frog-pile/.worktrees/missing",
            "branch": "lane/missing",
            "head": null,
            "landing": null,
            "commitsAhead": [],
            "commitsBehind": null,
            "freshness": null,
            "tracked": {
              "paths": [],
              "allowedChurnPaths": [],
              "blockingPaths": [],
              "allowlist": [
                "prototype-game/addons/playbot/playbot_common.gd.uid",
                "prototype-game/addons/playbot/playbot_export_plugin.gd",
                "prototype-game/addons/playbot/playbot_export_plugin.gd.uid",
                "prototype-game/addons/playbot/playbot_log_capture.gd.source",
                "prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid",
                "prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid",
                "prototype-game/addons/playbot/plugin.gd.uid",
                "prototype-game/project.godot"
              ]
            },
            "untrackedPaths": [],
            "ignoredPaths": [],
            "indexFlags": [],
            "operations": [],
            "submodules": {
              "inspected": [],
              "persisted": [],
              "unreadable": []
            },
            "gitRegistration": null,
            "blockers": [
              {
                "code": "missing-root",
                "message": "Workspace root is missing: <fixture>/frog-pile/.worktrees/missing"
              }
            ]
          }
        ],
        "blockers": [
          {
            "code": "missing-root",
            "message": "Workspace root is missing: <fixture>/frog-pile/.worktrees/missing"
          }
        ],
        "freshness": null,
        "retirable": false,
        "verdict": "blocked"
      }
    ]
  }
}
```

## dispatch: landingBranch without newWorkspace is rejected before any side effect

```
$ fm-playbot-lanes call dispatch '{"project":"FrogPile","workspace":"ws-ahead","thread":"Hop animation","message":"x","landingBranch":"proto/godot/frog-pile"}'
dispatch landingBranch is only valid together with newWorkspace; an existing workspace's freshness is read with get_workspace_freshness or get_thread_status
```

## dispatch: newWorkspace with blank landingBranch is rejected before creating anything

```
$ fm-playbot-lanes call dispatch '{"project":"FrogPile","newWorkspace":{"branch":"lane/new"},"message":"x","landingBranch":"  "}'
dispatch requires an explicit landingBranch
```

## tools/list served over MCP: every inputSchema root is a plain object (no oneOf/anyOf/allOf/not)

```
$ printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | fm-playbot-lanes serve | node -e '...summarize roots...'
list_projects                type=object rootCombinators=[]
list_threads                 type=object rootCombinators=[]
identify_current_thread      type=object rootCombinators=[]
create_workspace             type=object rootCombinators=[]
get_workspace_freshness      type=object rootCombinators=[]
list_retirable_workspaces    type=object rootCombinators=[]
retire_workspace             type=object rootCombinators=[]
create_chat                  type=object rootCombinators=[]
send_message                 type=object rootCombinators=[]
read_thread                  type=object rootCombinators=[]
get_thread_status            type=object rootCombinators=[]
list_parked_threads          type=object rootCombinators=[]
get_thread_card              type=object rootCombinators=[]
answer_thread_card           type=object rootCombinators=[]
list_queued_messages         type=object rootCombinators=[]
drop_queued_message          type=object rootCombinators=[]
register_lane                type=object rootCombinators=[]
dispatch                     type=object rootCombinators=[]
list_lanes                   type=object rootCombinators=[]
close_lane                   type=object rootCombinators=[]
archive_chat                 type=object rootCombinators=[]

list_parked_threads schema:
{
  "type": "object",
  "properties": {
    "project": {
      "type": "string",
      "description": "Optional project id, root path, or unique project name; every project when omitted. When present, landingBranch is required and landingBranches is rejected."
    },
    "landingBranch": {
      "type": "string",
      "description": "Explicit landing branch for a project-scoped read; required with project and rejected without it"
    },
    "landingBranches": {
      "type": "object",
      "description": "Optional global-scope map from project id, root path, or unique name to its explicit landing branch; valid only when project is omitted",
      "additionalProperties": {
        "type": "string"
      }
    }
  },
  "required": [],
  "additionalProperties": false,
  "description": "Either project with landingBranch, or neither with an optional landingBranches map; the server enforces this at call time."
}
```

## zero writes: FrogPile .git content hash, refs hash, and object counts before vs after every call above

```
$ snapshot before/after
before: 1da83fea3f0dc96e
08b823f509271d46
count: 15 in-pack: 0 
after:  1da83fea3f0dc96e
08b823f509271d46
count: 15 in-pack: 0 
IDENTICAL => the freshness surface wrote nothing to the workspace repository
```
