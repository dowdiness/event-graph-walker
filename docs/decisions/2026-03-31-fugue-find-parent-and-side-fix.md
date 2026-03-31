# ADR: Fix find_parent_and_side to match Fugue paper Algorithm 1

**Date:** 2026-03-31
**Status:** Accepted

## tl;dr

- Context: `find_parent_and_side` had a special-case `(None, _) -> (root, Right)` branch that deviated from the Fugue paper's Algorithm 1 (Weidner & Kleppmann 2023, arXiv:2305.00583, lines 25-28). The deviation went undetected because convergence tests pass even with wrong positioning -- they only check that replicas agree, not that characters land where requested.
- Decision: Align with Algorithm 1 -- use `is_ancestor(left, right)` for all cases, treating `origin_left = None` as `left = root`.
- Consequences: BREAKING for saved documents created with old behavior. Position cache optimization now works correctly. Property test L5.8 permanently guards the fix.

## Problem

The FugueMax implementation has three layers with an implicit contract between them:

1. **FugueTree** (`internal/fugue/tree.mbt`) -- the ordered tree CRDT. `find_parent_and_side` determines where a new character is placed in the tree based on `origin_left` and `origin_right` anchors.
2. **Document** (`text/text_doc.mbt`) -- translates position-based operations (`insert(pos, char)`) into origin-based CRDT operations by finding the left and right neighbors at the given position.
3. **PositionCache** -- an optimization that caches the mapping between positions and tree locations, assuming that characters are placed where the position-based API requests them.

The old `find_parent_and_side` had this logic:

```
match (origin_left, origin_right) {
  (None, _)     => (root, Right)   // <-- WRONG
  (_, None)     => (origin_left, Right)
  (Some(l), Some(r)) =>
    if is_ancestor(l, r) => (r, Left)
    else                 => (l, Right)
}
```

The `(None, _) => (root, Right)` branch ignores `origin_right` entirely. According to Algorithm 1, lines 25-28 of the Fugue paper:

- If leftOrigin has **no right children**, the new node becomes a right child of leftOrigin (line 26).
- If leftOrigin **has right children**, the new node becomes a left child of rightOrigin (line 28).

The paper's condition "has right children" is equivalent to `is_ancestor(leftOrigin, rightOrigin)` in the tree -- if leftOrigin is an ancestor of rightOrigin, the path runs through leftOrigin's right subtree, meaning right children exist.

When `origin_left = None`, the effective left origin is root. Since root is always an ancestor of every node in the tree, `is_ancestor(root, origin_right)` is always true when `origin_right` exists. The correct placement is therefore `(origin_right, Left)` -- a left child of the right origin, which places the character at the beginning of the document.

The old code instead made it a right child of root, which places the character at the **end** of the document.

### Symptom

Inserting at position 0 on a non-empty document placed the character at the end instead of the beginning. This violated the position round-trip contract: after `insert(0, 'X')`, the caller expects `text()[0] == 'X'`, but the character appeared at `text()[len-1]`.

### Why it went undetected

The existing property tests verified:
- **Convergence** (L7.1): all replicas produce identical text. This passes regardless of where characters are placed, as long as all replicas place them in the same wrong spot.
- **Non-interleaving** (L5.6): concurrent sequences remain contiguous. This is a relative ordering property and does not check absolute position.

No test verified the absolute position contract: that `insert(pos, ch)` actually places `ch` at position `pos`.

### Cascade bug

The position cache optimization assumed the position round-trip property held. When characters were misplaced by `find_parent_and_side`, the cache state diverged from the actual tree state, causing incorrect position lookups for subsequent operations.

## Decision

Replace the special-case `(None, _)` branch with the uniform algorithm from the Fugue paper:

```moonbit
let left = match origin_left { Some(l) => l; None => root_lv }
match origin_right {
  None => (Some(left), Right)
  Some(right) =>
    if self.is_ancestor(left, right) { (Some(right), Left) }
    else { (Some(left), Right) }
}
```

This handles all cases uniformly. When `origin_left = None` and `origin_right = Some(r)`:
- `left = root_lv`
- `is_ancestor(root_lv, r)` is always true (root is ancestor of everything)
- Result: `(Some(r), Left)` -- the character becomes a left child of `r`, placing it before `r` in document order, i.e., at position 0.

## Consequences

**BREAKING:** Existing saved CRDT documents created with the old behavior will produce different text when loaded by new code. The tree structure is persisted as part of the CRDT state (each item's parent and side are fixed at insertion time), so old documents remain internally consistent -- but new inserts-at-0 will go to a different place than old code would have put them. All replicas must be on the same code version.

**Position cache correctness:** The position cache optimization now works correctly for ALL positions, including position 0. Before this fix, the cache diverged from the tree for inserts at position 0.

**Property test guard:** Law L5.8 (position round-trip) permanently guards against future regressions:

```
For all positions p in [0, len(doc)], characters c:
  After insert(p, c): text()[p] == c
```

Tested by `prop_insert_position_roundtrip` in `text/position_roundtrip_properties_test.mbt`.

## Lessons

1. **Property tests must verify the API contract, not just convergence.** Convergence tests check that replicas agree, but they do not check that the agreed-upon result is *correct* from the user's perspective. The position round-trip property (`insert(p, c)` puts `c` at position `p`) is part of the API contract and must be tested independently.

2. **Incremental optimizations amplify latent semantic bugs.** The position cache was a correct optimization given its assumption (characters go where requested). The latent bug in `find_parent_and_side` violated that assumption, turning a silent misplacement into an observable cache corruption. Optimizations that depend on semantic invariants should reference the specific law they depend on.

3. **When implementing from a paper, reference the specific algorithm and line numbers in code comments.** The original implementation did not cite Algorithm 1 lines 25-28. The fix adds a detailed block comment above `find_parent_and_side` explaining the correspondence. This makes future audits straightforward: anyone can compare the code against the paper without reverse-engineering the intent.

## References

- Weidner, M. & Kleppmann, M. (2023). "The Art of the Fugue: Minimizing Interleaving in Collaborative Text Editing." arXiv:2305.00583. Algorithm 1, lines 25-28.
- Law L5.8 in `docs/FORMAL_SPECIFICATION.md`, Section 5.
- `internal/fugue/tree.mbt`: `find_parent_and_side` function.
- `text/position_roundtrip_properties_test.mbt`: `prop_insert_position_roundtrip`.
