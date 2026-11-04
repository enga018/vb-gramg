# VBGRAMG UI Design Specification

**Status:** Proposed design direction  
**Scope:** Visual system and interaction patterns for the existing VBGRAMG web application  
**Target devices:** Android/mobile browsers and desktop browsers (Windows)  
**Implementation status:** Documentation only. This specification does not authorize changes to page behaviour, data models, authentication, calculations, or database operations.

## 1. Design direction

VBGRAMG will use a **modern SaaS administrative dashboard** visual language.

The interface should feel like a well-designed, dependable operations platform: clear information hierarchy, efficient workflows, consistent controls, and readable data. It should not imitate a legacy government portal, and it should avoid decorative dashboard clutter.

### Core principles

1. **Clarity before decoration.** Prioritize labels, values, status, and next actions.
2. **Operational density with breathing room.** Show useful information without oversized cards or excessive whitespace.
3. **Consistency across modules.** Shared controls should look and behave the same on every page.
4. **Responsive by design.** Mobile and desktop are deliberately designed layouts, not one layout squeezed to fit.
5. **Preserve workflow semantics.** A visual redesign must not alter business rules or the meaning of any action.
6. **Trustworthy financial presentation.** Amounts, balances, dates, and transaction status must remain precise and unambiguous.

## 2. Visual foundation

### Colour

Use a light-first interface with a restrained blue accent.

| Token | Intended use | Proposed value |
|---|---|---|
| App background | Main page canvas | `#F6F8FC` |
| Surface | Cards, panels, dialogs | `#FFFFFF` |
| Primary text | Headings and key values | `#172033` |
| Secondary text | Hints, metadata, descriptions | `#667085` |
| Border | Dividers and control outlines | `#E3E8F0` |
| Primary | Main actions, active navigation, links | `#2563EB` |
| Primary-soft | Selected/active backgrounds | `#EFF6FF` |
| Success | Settled, completed, confirmed | `#15803D` |
| Warning | Deferred, attention required | `#B45309` |
| Danger | Due, rejected, destructive actions | `#B42318` |
| Neutral status | Inactive, closed, informational | `#667085` |

Status must never rely on colour alone. Pair colour with a clear text label or a meaningful icon. Do not use red/green as general decoration.

### Typography

- Use the system sans-serif stack for performance and platform-native readability.
- Use a clear type scale: page title, section title, body, metadata, and compact table labels.
- Use tabular numerals for money, counts, and aligned numeric columns where supported.
- Use semibold/bold weights for values and labels; avoid excessive all-caps text.
- Maintain readable contrast and avoid tiny text for important statuses or actions.

### Shape, spacing, and elevation

- Use a consistent spacing scale based on 4px increments.
- Use modest corner radii: controls around 8–10px; cards and larger surfaces around 12–16px.
- Prefer subtle borders and restrained shadows. Avoid stacking multiple shadowed cards inside one another.
- Use dividers and grouping before adding more cards.
- Keep touch targets comfortable on mobile (generally at least 44px high).

## 3. Application shell and navigation

### Desktop

- Target a persistent left navigation sidebar for the main application modules.
- Keep the content area aligned to a consistent maximum width and use available desktop space efficiently.
- The sidebar should identify the current module clearly and provide predictable access to MIS, FTO, Work Demand, Periods, and Contribution.
- Keep page-level actions in a consistent header area, separated from global navigation.
- Do not introduce a second competing navigation system.

### Mobile

- Use a compact header with a clear page title and a single navigation entry point (drawer/menu).
- Keep navigation reachable without consuming excessive vertical space.
- Use full-width or appropriately grouped actions; avoid narrow rows of crowded buttons.
- Respect safe areas and avoid horizontal page scrolling.

### Page header

Every module should follow one shared header pattern:
- Page title on the left.
- Relevant page actions on the right (wrapping cleanly on small screens).
- A short, useful description below the title when needed.
- A consistent route back to the main menu.
- Avoid repeating account/admin status text when it does not help the task.

The existing shared navigation and header implementation must be assessed before replacing it. Any transition from the current three-dot navigation to a desktop sidebar/mobile drawer must be planned and tested as a single coherent change.

## 4. Shared component standards

Create and maintain reusable visual patterns for:

- Primary, secondary, tertiary, and destructive buttons.
- Text inputs, selects, date fields, and text areas.
- Search and filter toolbars.
- Status badges and status indicators.
- KPI/statistic summaries.
- Data tables and mobile record rows.
- Empty, loading, error, and success states.
- Confirmation dialogs and full-screen mobile dialogs.
- Toast notifications.
- Pagination and “show more” controls.
- Page headers and navigation.

### Buttons

- Primary: one visually dominant action per task area.
- Secondary: supporting actions with a quiet neutral treatment.
- Destructive: clearly labelled and visually distinct; require confirmation when the action is irreversible.
- Disabled/loading states must be obvious.
- Button labels should describe the action, not use vague labels such as “OK” where a more specific label is possible.

### Tables and record lists

- Use clear column headings, consistent alignment, and restrained row separators.
- Right-align amounts and other numeric values.
- Keep identifiers and dates readable; avoid truncating values needed to identify a record.
- Use sticky table headers only where they improve long-list navigation.
- Provide an intentional mobile presentation instead of forcing wide desktop tables onto a phone.
- Preserve sorting, filtering, pagination, selection, and row-expansion behaviour exactly.

### Feedback states

Every data-loading page must distinguish:
- Initial loading
- Refreshing
- Empty result
- Recoverable error with a retry action where appropriate
- Successful completion
- Permission/access failure

Never leave the user with an unexplained blank area or an indefinite spinner.

## 5. Responsive layout standards

### Desktop and larger screens

- Use a consistent content grid and align panels to it.
- Use multi-column layouts for summary information where they improve scanning.
- Keep tables readable without excessive width or tiny type.
- Use available width for detail views and complex workflows, especially Contribution and FTO.

### Mobile

- Design around the actual tasks performed on a phone.
- Convert complex tables into structured rows/cards where appropriate.
- Keep key identity fields and the most important status/amount visible without opening a record.
- Avoid horizontal scrolling for primary workflows.
- Place frequent actions within comfortable reach and avoid overly dense action clusters.
- Use full-screen dialogs for complex record details when that provides better usable space.
- Ensure pagination and long lists remain manageable.

### Accessibility and interaction

- Support keyboard focus and visible focus states.
- Use semantic headings, labels, buttons, and table markup.
- Provide accessible names for icon-only controls.
- Support Escape to close dismissible dialogs/menus where appropriate.
- Respect reduced-motion preferences.
- Do not communicate state by colour alone.

## 6. Module-specific design requirements

These requirements describe presentation only. Existing business rules and workflow behaviour remain authoritative.

### Home and sign-in — `index.html`

- Keep authentication as the first gate; do not expose module content before sign-in.
- Present the modules as a clear application launch area after authentication.
- Use a restrained welcome/header area and consistent module navigation.
- Keep login fields and feedback states simple, accessible, and mobile-friendly.
- Do not add sample KPI values or invented operational data to the live dashboard.

### MIS — `mis.html`

- Make the search/filter area easy to locate and use.
- Present job-card groups with a clear distinction between job card/household identity and applicant details.
- Preserve the one-selected-applicant-per-job-card rule and its existing visual state.
- Mobile rows should prioritize job card and applicant identity, with selection control easy to reach.
- Desktop may use a denser table-like presentation.
- Keep import and refresh actions distinct and preserve the existing import confirmation workflow.
- KPI labels and their definitions must remain unchanged unless separately approved.

### FTO history — `fto.html`

- Make FTO number, contribution period, status summary, last imported/checked time, and actions easy to scan.
- Keep View and Change Period actions predictable and visually consistent.
- Use a spacious transaction detail view; do not make secondary metadata compete with the transaction amount and status.
- Preserve existing status interpretation and period-change behaviour.

### FTO import — `fto-import.html`

- Treat import as a guided, multi-step operational workflow.
- Give the paste/source-data area sufficient space and clear instructions.
- Visually separate automatic import, manual review, already imported, and cannot import outcomes.
- Make the review/confirmation stage especially clear before any write operation.
- Preserve the official raw-data paste workflow, parsing, matching, review, and confirmation semantics.

### Contribution — `contribution.html`

- Treat this as a financial operations interface: precision and auditability take priority.
- Make search, status filter, and due/settled information easy to scan.
- Keep job-card identity, household identity, and balance visually distinct.
- Maintain clear settled/due/overpaid/deferred/exempt states with text as well as colour.
- The citizen ledger detail should prioritize the job card and household heading, current balance, period summaries, and chronological transaction history.
- Keep edit controls behind the existing explicit Edit mode.
- Preserve FIFO allocation presentation, payment/refund/waiver distinctions, deferred-charge treatment, and all existing calculation/write behaviour.
- Ensure the desktop table and mobile list both expose the same underlying information.

### Periods — `periods.html`

- Present periods as a clean list/table with clear period name, contribution month/date, and open/closed state.
- Keep creation and management actions subordinate to the period list.
- Make destructive actions clearly distinct and retain existing eligibility restrictions.
- On mobile, each period should remain readable without horizontal scrolling.

### Work Demand — `demand.html`

- Present setup inputs as a focused, ordered workflow.
- Separate the main demand list, Manual Review, and Unwilling to Work views without making the user lose context.
- Keep job-card/applicant identity and outstanding amount clear in Manual Review.
- Make generation, save, and export states explicit.
- Preserve the current period linkage, applicant selection, manual inclusion, pagination, and export rules.
- Ensure report formatting remains a separate export concern rather than adding print-only headings to the working screen.

## 7. Motion and feedback

- Use short, subtle transitions for hover, focus, menu, and dialog states.
- Avoid animated counters, decorative motion, and layout shifts.
- Loading feedback should communicate what is happening when the operation takes noticeable time.
- Confirm destructive or financially significant actions before committing them.
- After a successful operation, show a concise confirmation and update the relevant visible data.

## 8. Performance and implementation constraints

- The redesign must not add heavy UI frameworks or unnecessary runtime dependencies.
- Prefer shared CSS variables and reusable CSS/component patterns over duplicated page-specific styling.
- Review the existing `responsive.css`, `navigation.js`, `toast.js`, and page-level styles before deciding what should be consolidated.
- Do not combine a visual redesign with cache/data-loader changes, Supabase changes, schema migrations, or financial calculation changes.
- Preserve authentication, role checks, API payloads, database writes, audit history, imports, exports, and all domain rules.
- Keep the current page-specific scripts and data-loading paths stable unless a separately reviewed change requires otherwise.

## 9. Recommended implementation sequence

1. **Approve this specification.** Resolve any disagreements before UI implementation.
2. **Establish a visual baseline.** Capture representative desktop and mobile states for every module, including loading, empty, error, list, and detail states.
3. **Define shared design tokens and components.** Establish colours, typography, spacing, buttons, inputs, status badges, tables, dialogs, and page headers.
4. **Implement the application shell.** Login/home, desktop navigation, mobile navigation, and shared page header.
5. **Redesign one module at a time.** Recommended order: MIS, FTO history/import, Periods, Work Demand, then Contribution.
6. **Verify functional parity.** Compare the same records and actions before/after; verify that only presentation changed.
7. **Test on both target classes.** Android phone and Windows desktop, including narrow and wide viewports.
8. **Merge in small reviewed PRs.** Do not merge or deploy until the relevant mobile and desktop checks pass and the change is approved.

## 10. Acceptance criteria

A redesigned page is ready only when:

- It follows the approved tokens and shared component patterns.
- It has a deliberate mobile and desktop layout.
- There is no unintended horizontal page overflow.
- Important data, identifiers, amounts, and statuses remain readable.
- Loading, empty, error, and success states are usable.
- Keyboard focus and accessible labels are present for interactive controls.
- Existing business behaviour and displayed values match the pre-redesign baseline.
- No unrelated data, authentication, Supabase, cache, or financial logic changes are included.
- The page has been checked on both Android/mobile and Windows/desktop before merge.
