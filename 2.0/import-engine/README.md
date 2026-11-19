# Import Engine

Planned independent import subsystem, testable without the VB-GRAMG application UI.

## Planned components

| Component | Responsibility |
|---|---|
| core | Shared import lifecycle, contracts and result types |
| connectors | Government portal access and source retrieval |
| parsers | Convert source formats into structured records |
| normalizers | Standardise values while preserving source data |
| validators | Check required fields, duplicates and jurisdiction |
| comparison | Detect additions, modifications, deletions and unchanged records |
| staging | Hold proposed changes for review before activation |
| tests | Fixtures, parser tests, validation tests and regression tests |

## Implementation order

1. Import Engine foundation
2. Employment Register adapter
3. Employment Register validation and comparison
4. FTO adapter
5. Integration and regression testing

## Reuse from VB-GRAMG 1.0

The existing 1.0 MIS importer and relevant tests will be inspected and used as the starting reference for the Employment Register adapter. The 1.0 implementation remains unchanged.

**Preview only:** no production importer code is present here yet.
