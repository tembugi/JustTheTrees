# Just the Trees

This addon's spec. The shared rules in `../CLAUDE.md` come first: they hold every rule that isn't this addon's own and win on any conflict.

@../CLAUDE.md

A mock talent planner in its own "Just the Trees" tab on the talent window: separate mock trees the player fills as if they had max points. Agreed with the user.

- Name "Just the Trees" (folder, repo and packages `JustTheTrees`; `ADDON_TITLE`, also the tab text). CurseForge project ID 1716979. For players who want simplicity, no extra features, and a look that belongs in the WoW Forever / Classic UI.

## Never
- Never touch the character's talents, and never read spent points, ranks or progress from them. Reading the tree's fixed data is fine: layout, max ranks, arrows, gates, icons, tooltips and art.

## Look and logic
- The look and the working logic are 1:1 with the game's talent window. The look and UX are set; change them only when the user asks.
- Where the game has code or a template for a part, the plan uses it: talent states are drawn by `TalentButtonArtMixin:ApplyVisualState` (Forever's border rule: green until maxed, yellow when maxed), gates are `TalentFrameGateTemplate`, search marks `TalentButtonSearchIconTemplate`, and the pulse on talents that can take a point copies `SelectableGlow`.
- The plan's controls are the game's (the user's choice, 2026-10-17): Apply Changes in ApplyButton's place, glowing (its YellowGlow) while the plan differs from the saved one; the undo arrow ("Undo Pending Changes": back to the saved plan, or none) shows then, and otherwise the reset arrow (Clear), as the game shows UndoButton and ResetButton. Clicks on talents play the game's spend and refund sounds; Apply Changes plays its apply sound and the game's apply effect (class and background flashes, then a spark on each talent learned since the last save with the completion sound), rebuilt on the addon's own textures and model scene.
- Tooltips are built like the game's talent tooltips: the talent tooltip backdrop, rank, the rank's text, next rank, "Click to learn" or "Right click to unlearn", then the row requirement and "Requires all preceding talents".
- Gates: the game's gate on the first locked row of each tree, with the points the plan still needs; hovering it shows the game's gate sentence.
- Clicks as on the game's buttons: left adds a point, right removes one, shift-click puts the talent's link in chat.
- Inspecting another player while the tab is open hands the window to their talents. The tab is off while inspecting.
- The tab is the addon's own button after Primary and Secondary, made from the game's tab template, never one of the game's tabs: a tab added to the game's tab bar made every open of the talent window run the game's code tainted (taint log, 2026-10-17). Under the plan the game's tree and controls stay as the game drew them, see-through and shielded from the mouse; the game's selected tab is drawn unselected, and a click on any game tab brings the game's tree back. The addon never calls the game's tab, tree or window functions.
- Turned off after an error (the shared Errors rule): the plan's tab is hidden, not greyed out (the user's choice), and the character's own talents come back, until /reload.
- Below the talent level the talent button and window stay as the game has them (the talents tab shut). The user dropped the below-level open (2026-10-17): opening the window from the addon tainted it and the action bars, so actions were blocked in combat, and a secure button pressing the game's buttons was rejected.
- The version shows as `v<VERSION>` on the left end of the unspent points row, and the title "Just the Trees" in the game's gold title font in the center of that row, both only on the calculator tab.
- Chat names talents by their links.
- Search marks come from the talent window's own search and use the game's search mark (`TalentButtonSearchIconTemplate`: the icon for each match type, its pulse and its hover text), on talent buttons and on each choice. "Not on your action bar" marks are left out: planned talents are not on the character's bars.

## Points
- Budget: 51 points, one per level from 10 to 60 (`PLAN_BUDGET`).
- "Level required" label: "-" until the first point is spent (the first point is spent at level 10), then 9 + points spent, capped at 60.
- No level-locked talents: only the row rule below opens rows.

## Rows
- Row 1 of a tree is open. Row n needs 5 × (n − 1) points spent in the rows above it, in the same tree (row 2 = 5, row 3 = 10, row 4 = 15, …). Points in the same row, deeper rows or other trees do not count.
- A point cannot be removed when that would leave a deeper talent short, or break an arrow requirement.
- This is a fixed rule in the code (`ApplyRowRequirements`), not read from the client: in game a gate's `spentAmountRequired` is what the character still needs (the talent window shows it as is), so reading it would read the character's points. The game's data (wago, 2026-10-17) has 5 more per row in every class tree; a few talents sit a few units off their row, so talents within 150 of a row (rows are 600 apart) belong to it.

## Saves
- Per character (name-realm), two independent plans: Primary (`build`) and Secondary (`secondary`). They are the calculator's own slots, not the character's spec slots, and not tied to a spec id.
- Primary is shown first. Unsaved edits are kept per slot for the session.
- `NormalizeSaved` rebuilds `JustTheTreesDB` on every load: `format`, then per character the two plans, each a list of `nodeID`, `ranks`, `entryID`. Ranks are whole numbers from 1 to the budget, and each node appears once.
- A plan shown on the tree is fitted to it (`FitPlanToTree`): ranks capped at the talent's max, a choice the node no longer has becomes its first one, and points over the budget come off the deepest rows.
- Own class only.

## Tests
- `Tests/run.lua` runs the saved-plan tests and the plan tests. Both play the unchanged `Core.lua` in `Tests/standin.lua`: Forever's talent window, copied from `wow-ui-source`, over a small made-up class tree (three trees with arrows, a choice, a tiered talent, two talents that shut each other out, an empty row, and the character's own points, which the plan must never read or change). The stand-in records the game's own tab, tree and window code, and the game's widget scripts, that the addon's code runs; a test plays a whole session and expects none.

## Logo
`Logo/JustTheTrees-logo.svg`: a gold double ring and a 3 x 4 grid of talent squares in gold, green and grey with two arrows, redrawn from the PNG on CurseForge, whose colours were measured.
