# Diagram (only when a picture beats the prose)

Draw as the engineer who has to live with the change, not as a decorator. A diagram earns its place when it lets a cold reader see a mechanism they would otherwise assemble from prose. If a sentence says it faster, write the sentence and skip the diagram.

## When to draw (any one of these; otherwise do not)
1. **A call chain changed**: the changed symbol has callers in two or more files, or a caller is `← outside diff`.
2. **Data flow changed**: a value now crosses a boundary it did not before (new I/O, queue, cache, service hop), or stops crossing one.
3. **State transitions changed**: a request or record moves through a different sequence of states.
4. **Two options are being compared** (rejected-alternatives ledger): draw the one edge each option adds or removes, side by side.

## What to draw
- Depict the **mechanism**, not its name. A box labelled "cache" says less than the prose; the request's path through it, the two stores it sits between, and the arrow that disappears when it is removed say what words cannot.
- **Before → After** is the default form for 1–3: left the old graph, right the new one, the removed edge dashed in the old, the added edge in the one accent colour in the new. Nodes are symbols or files (`newName()`, `src/caller.ts`), not concepts.
- **Comparison** (4): two small graphs that differ only in the edge being chosen between; nothing else.
- **Label every arrow**: `calls`, `writes`, `reads on start`, `polls every 30s`. An unlabelled arrow means "related somehow".
- Match size to the stakes: a one-hop change is three boxes; a migration that reroutes writes needs the queue, the writer, the reader and the ordering arrow. No forced minimalism, no inventory of the whole system.
- One figure, one claim. The caption states the claim in one sentence; the `aria-label` carries the same claim.

## How to draw (self-contained, works in any browser and for any agent)
- Inline `<svg>` with native shapes (`rect`, `line`, `path`, `polygon`, `text`) and a `<marker>` arrowhead. No libraries, no CDN, no `<script>`, no images, no `<foreignObject>`.
- `viewBox="0 0 W H"` sized to the content; CSS scales it (`max-width: 100%; height: auto`). Flows read left to right.
- Strokes and text in `currentColor` so the page's light and dark themes both work; one literal accent colour for the element the change hinges on, readable on both backgrounds.
- Text 11–13px at drawn scale, labels of one to three words; sentences go in the caption.
- Align to a grid: shared baselines, even gaps.
- Put `path:line` under each node that maps to code, so the figure and `PR_QA.md` point at the same places.

Start from `assets/diagram_template.html` (it holds the page chrome, theme CSS and the arrow marker). Replace the `<!-- SVG -->` block and the caption.

## Output
Write `.pr-grill/<branch>/diagram.html` and print one line the terminal turns into a link:
```
Diagram: file:///abs/path/.pr-grill/<branch>/diagram.html   (<claim in a few words>)
```
In Claude Code, also offer to publish it as a private page (the Artifact tool) when the author wants a URL to share or open on a phone; the file stays the canonical copy. Add the same claim and the file path to `PR_QA.md` under the section it illustrates.
