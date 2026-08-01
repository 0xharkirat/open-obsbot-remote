# Decide the mix sequence authoring and persistence model

`wayfinder:grilling` - HITL - status: **open, on the frontier**

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

_Unresolved._
