# Jev wiki rule audit

- Wiki: /tmp/wiki-audit-demo/wiki
- Generated: 2026-10-06T07:32:32Z in shadow mode with confidence floor 0.8
- Rule file: /tmp/wiki-audit-demo/rules.json (2 rules)
- Pages: 2, of which 0 needed more than one chunk
- Consultations: 2 answered of 2
- Spend on answered consultations: US$0.000010 for 231 input tokens

Each rule asks whether the page violates it; yes is a flag. A flag is listed only when its confidence met the floor. Nothing in the wiki was changed.

## Per-rule counts

| Rule | Pages flagged | Flagged below the floor | Not judged confidently | Source |
| --- | --- | --- | --- | --- |
| `hedge` | 0 | 0 | 0 |  |
| `history` | 0 | 0 | 0 | fixture style guide |

## Per-page flags

| Page | Rules flagged (confidence) | Chunks |
| --- | --- | --- |
| design/two.md | none | 1 |
| one.md | none | 1 |

## Pages Jev could not judge confidently

None.

## Chunked pages

None.

## Spend

- Answered consultations: 2, US$0.000010, 231 input tokens
- Unanswered consultations: 0
- Pages split again after a rejected request: 0; spend on answered chunks of a discarded attempt is included above
- Every attempt, including failed ones, is also in the Jev ledger; `bin/fm-jev-report.sh` reads it.
