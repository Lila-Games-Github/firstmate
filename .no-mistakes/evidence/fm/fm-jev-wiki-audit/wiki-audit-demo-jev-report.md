# Jev wiki rule audit

- Wiki: FrogPile wiki (synthetic demo)
- Generated: 2026-10-06T07:05:55Z in active mode with confidence floor 0.8
- Rule file: bin/jev-questions/wiki-audit.json (built-in) (13 rules)
- Pages: 6, of which 0 needed more than one chunk
- Consultations: 6 answered of 6
- Spend on answered consultations: US$0.000819 for 19493 input tokens

Each rule asks whether the page violates it; yes is a flag. A flag is listed only when its confidence met the floor. Nothing in the wiki was changed.

## Per-rule counts

| Rule | Pages flagged | Flagged below the floor | Not judged confidently | Source |
| --- | --- | --- | --- | --- |
| `archived_evidence_outside_sources` | 1 | 0 | 0 | Documentation schema, current-state and source rules; product-owner audit feedback item 4 |
| `attributed_quotation` | 0 | 0 | 0 | Documentation schema, filing and verbal-design rules on attributed wording; product-owner audit feedback item 5 |
| `dated_ruling` | 1 | 0 | 0 | Documentation schema, verbal design and source-artifact boundary; product-owner audit feedback item 3 |
| `delivery_report_in_wiki` | 0 | 0 | 0 | Documentation schema, filing and linking rules |
| `design_and_implementation_mixed` | 0 | 0 | 0 | Product-owner audit feedback item 7 |
| `hedging_qualifier` | 1 | 0 | 0 | Product-owner audit feedback item 8 |
| `history_narration` | 1 | 0 | 0 | Documentation schema, current-state and source rules; product-owner audit feedback items 3 and 6 |
| `invented_source_record` | 0 | 0 | 0 | Documentation schema, verbal design and source-artifact boundary |
| `mislabeled_source_citation` | 0 | 0 | 0 | Documentation schema, current-state and source rules on citations |
| `missing_header` | 0 | 0 | 0 | Documentation schema, required page header |
| `provenance_narration` | 1 | 0 | 0 | Product-owner audit feedback items 5 and 6 |
| `supersession_narration` | 0 | 0 | 0 | Product-owner audit feedback item 6 |
| `unbacked_authority_date` | 0 | 0 | 0 | Documentation schema, required page header and verbal design rules |

## Per-page flags

| Page | Rules flagged (confidence) | Chunks |
| --- | --- | --- |
| audit-figjam-panels.md | `archived_evidence_outside_sources` 0.9 | 1 |
| design/clean.md | none | 1 |
| design/dated-ruling.md | `dated_ruling` 0.9 | 1 |
| design/hedge.md | `hedging_qualifier` 0.9 | 1 |
| design/history.md | `history_narration` 0.9 | 1 |
| design/provenance.md | `provenance_narration` 0.9 | 1 |

## Pages Jev could not judge confidently

None.

## Chunked pages

None.

## Spend

- Answered consultations: 6, US$0.000819, 19493 input tokens
- Unanswered consultations: 0
- Pages split again after a rejected request: 0; spend on answered chunks of a discarded attempt is included above
- Every attempt, including failed ones, is also in the Jev ledger; `bin/fm-jev-report.sh` reads it.
