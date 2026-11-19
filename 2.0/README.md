# VB-GRAMG 2.0 — Preview

This is a visual preview branch for planning the VB-GRAMG 2.0 Import Engine.

## Purpose

Develop and validate the import engine before building the 2.0 application interface.

## Planned first adapters

1. **Employment Register** — first implementation, based on the proven 1.0 MIS importer.
2. **FTO** — second implementation, covering Government FTO listings, transaction details, status detection and reconciliation.

## Proposed structure

```text
2.0/
└── import-engine/
    ├── core/
    ├── connectors/
    ├── parsers/
    ├── normalizers/
    ├── validators/
    ├── comparison/
    ├── staging/
    └── tests/
```

## Safety boundary

- This branch is separate from `main`.
- No files in the 1.0 application are being moved or modified.
- No importer code has been copied yet.
- No database, Supabase project, deployment or production workflow is changed.
- Nothing in this preview is merged into `main`.

This branch exists only so the proposed 2.0 layout can be inspected in GitHub before deciding how to organise the long-term work.
