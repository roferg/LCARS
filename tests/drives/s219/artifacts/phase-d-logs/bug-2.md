# Mission: Draft banner shows "Last edited —" instead of the last autosave time

**Type:** bug
**Goal:** The builder's Draft banner shows when the draft was last edited (e.g. "Last edited 2 min ago"), reflecting the latest autosave, whenever the draft has content.
**Acceptance Criteria:**
- With a draft that has been edited/autosaved, the Draft banner reads "Last edited <relative time>" (as in the drawing), not "Last edited —"
- After typing an insight and the autosave completing, the banner's time updates to the latest autosave
**Out of Scope:**
- Changing autosave timing or storage
**Constraints:**
- Resolved decision: "Autosave on blur + debounced while typing; no explicit save control; the "last edited" meta reflects the latest autosave."
- Reported by the product owner (stand-in). Their words: "The builder's Draft strip reads "Last edited — · 3 of 5 buckets complete," showing an em dash where a timestamp belongs (drawing-3 shows "Last edited 2 min ago"). The draft clearly contains authored insight prose, so an autosave has occurred and the meta should reflect it — per the resolved decision, "last edited" reflects the latest autosave. A blank timestamp on a draft with content is a visible defect, not a demo-date difference."
