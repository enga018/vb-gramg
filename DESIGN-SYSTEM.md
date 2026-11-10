# VBGRAMG Design System

**Status:** Foundation proposal on `design/vbgramg-design-system-foundation`  
**Scope:** Shared visual tokens for the existing VBGRAMG web application  
**Implementation approach:** Introduce tokens first, then migrate existing page styles in small reviewed stages.

## Design direction

VBGRAMG uses a modern, dependable administrative-dashboard visual language. The interface prioritizes readable operational data, clear actions, restrained decoration, and consistent mobile/desktop behaviour.

- Light mode is the default.
- Dark mode follows the device/browser `prefers-color-scheme` setting.
- Dark surfaces use charcoal tones and subtle borders; avoid heavy shadows.
- The brand/action palette is blue in light mode. Existing restrained teal primary actions are retained in dark mode for continuity.
- Financial/status meaning remains stable: green = paid/success, red = outstanding/error, amber = deferred/warning, blue = overpaid/information, neutral = exempt/inactive.
- Status must never rely on colour alone; retain visible text labels or meaningful icons.

## Colour construction

### Build scales, not isolated HEX values

The token stylesheet defines a brand scale and neutral scale. Scale values are primitives; components should consume semantic tokens rather than reference primitive HEX values directly.

### Name colours by role

Use semantic names such as:

- `--color-bg-canvas`
- `--color-bg-surface`
- `--color-text-primary`
- `--color-text-secondary`
- `--color-brand-primary`
- `--color-status-success`
- `--color-financial-outstanding`

Do not encode a shade number into component declarations when the intended meaning is a role.

### 60 / 30 / 10

Use this as a visual-balance guideline, not a literal CSS quota:

- **60% dominant neutral:** page canvas and large backgrounds.
- **30% supporting surfaces:** panels, tables, cards and navigation.
- **10% accent:** primary actions, selected states and focused highlights.

Do not use the accent colour as general decoration. Keep status colours reserved for actual status meaning.

## Tokens included

- Brand and neutral colour scales.
- Semantic background, border, text, brand/action and focus roles.
- Status and financial-state roles.
- Typography family, sizes and line heights.
- A 4px-based spacing scale.
- Border radii, border width and restrained elevation.
- Control heights and content max-width.
- Light and dark theme values.

## Implementation constraints

- This foundation does not change application markup or page behaviour by itself.
- Migrate pages from hard-coded values to semantic tokens incrementally.
- Keep business rules, financial calculations, FIFO allocation, Supabase calls, authentication, imports and exports unchanged.
- Do not append more page-specific dark-mode override patches as the long-term strategy; replace them gradually with shared semantic roles.
- Test each migrated page on Android/mobile and Windows/desktop in both light and dark modes.
- Preserve the agreed compact shared navigation and existing responsive layout decisions.

## Rollout sequence

1. Add and load the shared token stylesheet without changing rendered UI.
2. Migrate shared shell, navigation and toast styles.
3. Migrate MIS.
4. Migrate FTO history and FTO import.
5. Migrate Periods and Work Demand.
6. Migrate Contribution last, with financial/status regression checks.
7. Remove obsolete duplicated overrides only after parity is verified.
