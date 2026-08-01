# Decide the mix sequence authoring and persistence model

`wayfinder:grilling` - HITL - status: **CLOSED 2026-07-24**

## Question

How does an operator create, save, update, switch, and discard mix sequences, and how do they know at any moment whether their edits are safe?

## What triggered it

Two gaps reported from real use, which are one design question wearing two hats:

1. With a sequence loaded, there is no way to create a new one. The operator is trapped in the sequence they opened.
2. With a sequence loaded, there is no way to save changes back to it. Edit a step, add one, delete one, and the library copy stays as it was.

Underneath both sits the thing that was never designed: the relationship between the **scratch** sequence the engine runs and the **library** of saved ones. The bridge persists a scratch to `mix.json` and a library to `mix_sequences.json`, and the protocol has `mix.set`, `mix.save_as`, `mix.load`, and `mix.delete`. There is `save_as` but no `save`, and `load` overwrites the scratch with no notion of whether the scratch was dirty.

## What the decision has to cover

- **Create new** while something is loaded. What happens to the loaded one, and to unsaved edits in it?
- **Save versus Save as.** Does updating in place exist, and does the protocol need a `mix.save` beside `mix.save_as`?
- **Dirty state.** Does the operator get told their edits are unsaved, and does a stale edit survive a bridge restart? The scratch persists today, so edits already outlive a restart in a way the operator may not expect.
- **Switching away with unsaved work.** Warn, auto-save, or discard.
- **Rename and delete**, and what happens if the deleted sequence is the one currently running.
- **Editing a running sequence.** Whether it is permitted at all, and if so whether changes take effect on the current pass or the next one. This is the one with real stakes: it happens live, mid-service.

## Constraint

The operator is running this during a service with their attention on the room, not the screen. A model that is technically complete but needs thought at the wrong moment fails even when every button works. Prefer the arrangement with fewest ways to lose work by accident.

## Answer

**Resolved 2026-07-24. Three things that were one thing become three: what is SAVED, what is RUNNING, and what is being EDITED. Every reported gap dissolves once they are separated.**

### The root cause, found in the code

The reason there is no way to save back is not a missing button. `mix_set` in `apps/bridge_cpp/src/device_manager.cpp` contains:

```cpp
mix_loaded_.clear();   // editing scratch
```

**Editing detaches by design.** The moment any field changes, the bridge forgets which saved sequence you opened, so there is nothing left to save back to. The same function re-clamps the run cursor and can stop a running sequence outright if the edit empties it, which means today's edits reach a live show immediately.

That single line explains reported gaps 1 and 2 together, and reveals a third problem nobody reported: editing during a service is unsafe.

### 1. Edits go to a draft; the running show is a frozen snapshot

Pressing Run captures the sequence. Editing after that works on a draft and **cannot** affect the show. This is the load-bearing decision and everything else follows from it.

It makes editing during a service safe for the first time. Mid-diwan you may want to fix cue 5 while cue 2 is on air; today that edit lands instantly and can halt the sequence.

### 2. Save and Apply are separate acts

`Save` writes the library. `Apply to running sequence` swaps the new version into the show, **at the next cue boundary only** - never mid-move, never mid-crossfade. Apply is offered only while that sequence is the one running.

Saving is bookkeeping you might do at any moment. Changing what a congregation is watching is a deliberate act and deserves its own tap. While the two differ, the detail screen says so: `Running (2 edits not applied)`.

### 3. Navigation: list, then read-only detail, then edit mode

```
Sequences list  ->  tap "Full House"  ->  read-only detail  ->  Edit
                                          Run | Duplicate |          Cancel | Full House | Save
                                          Edit | Delete
```

- **Create new** is `+ New` on the list, or `Duplicate` from the detail.
- **Save back** writes to the sequence you opened. Unambiguous, because you entered through it.
- **There is no Save As.** Duplicate-then-edit replaces it, which removes the ambiguous Save/Save-As pairing that small screens handle badly.
- The **read-only detail is the pre-flight surface**. It is where the broken-preset warning decided in [the missing-preset ticket](04-preset-binding-semantics.md) belongs, sitting directly above the Run button, at the moment the operator is deciding to commit.

Editing is a distinct mode with `Cancel | Title | Save`, so **the mode is the unsaved indicator** and no dirty badge is needed.

### 4. The draft lives on the bridge

Persisted beside the running snapshot, the way the scratch is today. A browser reload, a backgrounded app, or a move from phone to Mac mid-edit all recover the draft intact.

The web app is the primary phone client and has a history of cache and reload trouble; losing 20 minutes of authoring to a tab refresh is exactly what makes an operator stop trusting a tool. The cost is that two clients would contend for one draft, which is acceptable for a single-operator venue, and the state event already broadcasts changes so a second client sees them arrive.

### Consequences the decisions settle by themselves

- **Switching away with unsaved work:** nothing is lost, because the draft persists on the bridge. Offer `Discard draft` explicitly rather than interrogating on every exit. If a confirmation is ever shown, the safe action is the filled primary and the destructive one is the low-emphasis text button.
- **Deleting a running sequence:** the show keeps running, because it holds a frozen snapshot and no longer depends on the library entry. Warn that it is live, and let it finish.
- **Editing a sequence that is not running:** no snapshot exists, so Save is the only act; Apply is not offered.

### What this leaves to build

**Bridge**
1. Stop clearing `mix_loaded_` on edit; the origin is what makes Save possible.
2. Split state into three: `library` (saved), `running` (snapshot taken at Run), `draft` (being edited, persisted).
3. New actions: `mix.save` (write draft to its origin), `mix.apply` (swap draft into the running snapshot at the next cue boundary), `mix.new`, `mix.duplicate`, `mix.rename`, `mix.discard_draft`.
4. `mix.set` stops mutating the running sequence. It writes the draft only.

**Remote**
5. Sequences list, read-only detail, and edit mode as above.
6. `Running (n edits not applied)` state on the detail, and the Apply action while live.
7. The pre-flight warning block on the detail, above Run.

**Docs**
8. `PROTOCOL.md`: the new actions and the draft/running/library distinction.

Interface treatments draw on [the Mobbin research](../../ui-ux-research/mobbin-findings.md): the read-only-detail-with-Duplicate shape, the draft-versus-active split, and a generated summary line on each library row (`6 cues, 4m 20s`).
