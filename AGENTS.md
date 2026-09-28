# TalentCalculator

Rules for this addon. The shared rules are in `../AGENTS.md`.

A mock talent planner in its own "Talent Calculator" tab on the talent window: separate mock trees the player fills as if they had max points. Agreed with the user.

## Never

- Never touch the character's talents, and never read spent points, ranks or progress from them. Reading the tree's fixed data is fine: layout, max ranks, arrows, gates, icons, tooltips and art.

## Look and logic

- The look and the working logic are 1:1 with the game's talent window. The look and UX are set; change them only when the user asks.
- The version shows as `v<VERSION>` on the left end of the unspent points row, only on the calculator tab.

## Points

- Budget: 51 points, one per level from 10 to 60 (`PLAN_BUDGET`).
- "Level required" label: "-" until the first point is spent (the first point is spent at level 10), then 9 + points spent, capped at 60.
- No level-locked talents: only the row rule below opens rows.

## Rows

- Row 1 of a tree is open. Row n needs 5 × (n − 1) points spent in the rows above it, in the same tree (row 2 = 5, row 3 = 10, row 4 = 15, …). Points in the same row, deeper rows or other trees do not count.
- A point cannot be removed when that would leave a deeper talent short, or break an arrow requirement.
- This is a fixed rule in the code (`ApplyRowRequirements`), not read from the client.

## Saves

- Per character (name-realm), two independent plans: Primary (`build`) and Secondary (`secondary`). They are the calculator's own slots, not the character's spec slots, and not tied to a spec id.
- Primary is shown first. Unsaved edits are kept per slot for the session.
- `NormalizeSaved` rebuilds `TalentCalculatorDB` on every load: `format`, then per character the two plans, each a list of `nodeID`, `ranks`, `entryID`. Ranks are whole numbers from 1 to the budget, and each node appears once.
- A plan shown on the tree is fitted to it (`FitPlanToTree`): ranks capped at the talent's max, a choice the node no longer has becomes its first one, and points over the budget come off the deepest rows.
- Own class only.
