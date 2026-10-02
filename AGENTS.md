# Just the Trees

Rules for this addon. The shared rules are in `../AGENTS.md`.

A mock talent planner in its own "Just the Trees" tab on the talent window: separate mock trees the player fills as if they had max points. Agreed with the user.

The name is "Just the Trees" (folder, repo and packages `JustTheTrees`; `ADDON_TITLE` in the code, also the tab text). CurseForge project ID: 1716979. It is for players who want simplicity, no extra features, and a look that belongs in the WoW Forever / Classic UI.

## Never

- Never touch the character's talents, and never read spent points, ranks or progress from them. Reading the tree's fixed data is fine: layout, max ranks, arrows, gates, icons, tooltips and art.

## Look and logic

- The look and the working logic are 1:1 with the game's talent window. The look and UX are set; change them only when the user asks.
- Where the game has code or a template for a part, the plan uses it: talent states are drawn by `TalentButtonArtMixin:ApplyVisualState` (Forever's border rule: green until maxed, yellow when maxed), gates are `TalentFrameGateTemplate`, search marks `TalentButtonSearchIconTemplate`, and the pulse on talents that can take a point copies `SelectableGlow`.
- Tooltips are built like the game's talent tooltips: the talent tooltip backdrop, rank, the rank's text, next rank, "Click to learn" or "Right click to unlearn", then the row requirement and "Requires all preceding talents".
- Gates: the game's gate on the first locked row of each tree, with the points the plan still needs; hovering it shows the game's gate sentence.
- Clicks as on the game's buttons: left adds a point, right removes one, shift-click puts the talent's link in chat.
- Inspecting another player while the tab is open hands the window to their talents. The tab is off while inspecting.
- The version shows as `v<VERSION>` on the left end of the unspent points row, and the title "Just the Trees" in the game's gold title font in the center of that row, both only on the calculator tab.
- Chat lines start with "Just the Trees:" in gold. Failures are red after it, and talents are named by their links.
- The addon's own labels and messages are English. Parts copied from the game use the game's own strings.
- Search marks come from the talent window's own search and use the game's search mark (`TalentButtonSearchIconTemplate`: the icon for each match type, its pulse and its hover text), on talent buttons and on each choice. "Not on your action bar" marks are left out: planned talents are not on the character's bars.

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
- `NormalizeSaved` rebuilds `JustTheTreesDB` on every load: `format`, then per character the two plans, each a list of `nodeID`, `ranks`, `entryID`. Ranks are whole numbers from 1 to the budget, and each node appears once.
- A plan shown on the tree is fitted to it (`FitPlanToTree`): ranks capped at the talent's max, a choice the node no longer has becomes its first one, and points over the budget come off the deepest rows.
- Own class only.
