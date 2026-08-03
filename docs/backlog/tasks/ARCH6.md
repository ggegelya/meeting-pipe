# ARCH6: dead seams, an unwired presentation model, and knobs that outlived their controls

Filed 2026-08-03 by the audit band. P3. Distinct from ARCH5, which is the duplication and extraction band; this is code that exists and is not reached.

## 1. `StatusBarModel`'s four decision functions have zero production callers

`StatusBarModel.derive` (`daemon/Sources/MeetingPipe/StatusBarModel.swift:121`), `title` (`:137`), `icon(for:)` (`:187`) and `rows` (`:207`) are called from nowhere in `daemon/Sources`. The shipped menu bar composes its own title (`StatusBarController.swift:265-276`), picks its own icon (`:138`, `:149`, `:164`, `:181`, `:200`) and builds its own conditional row set and order in `populateMenu` (`:427-611`), while 19 of the 31 `StatusBarModelTests` methods pin a parallel copy of those three decisions.

The divergence has already begun. `StatusBarController.swift:503` adds a `finishSetup` row that `StatusBarModel.Row` (`:26-46`) has no case for, so the tested row list already disagrees with the shipped menu. `StatusBarController.swift:391`'s `hasPendingPermissionIssue()` has no call site and has sat dead since the extraction.

`docs/backlog/q6-final.md:76` records T3 as having lifted these out of the controller. That claim is false and should be corrected in the archive.

The skeptic's narrowing, recorded: the **rest** of the type is genuinely load-bearing. Seven entry points are read by production (`StatusBarController.swift:268, 393, 404, 488, 519, 635, 693` and `Coordinator+MenuActions.swift:226`), five of them repointed by T3 itself, so "never repointed the controller at it" is false as a blanket statement. Only the four decision functions are orphaned.

Fix: repoint `applyTitle` at `StatusBarModel.title`, the icon at `StatusBarModel.icon`, and have `populateMenu` build its conditional items by switching over `StatusBarModel.rows` with a `finishSetup` case added, so `NSMenuItem` construction stays in the controller while presence and ordering live in one place. Delete the dead private method. Correct the T3 archive row. Green-to-green: the two title implementations agree today, so no user-visible string changes.

## 2. `PrepCardProviding` is an injection seam nothing injects

`daemon/Sources/MeetingPipe/PrepCard.swift:115` declares the protocol with the stated purpose at `:113` of keeping the prompt panel from learning where its data comes from. There is exactly one conformer, exactly one injection site that always passes it, and no test ever supplies a fake, so it buys neither testability nor substitution.

Fix: either use it (give the panel tests a fake provider, which is the cheap win if the panel has untested branches) or collapse it. Do not leave it as a seam that documents an intent nothing exercises.

## 3. Two `UISettings` knobs kept their plumbing after DSN1 cut their controls

`menuBarIconStyle` (`daemon/Sources/MeetingPipe/Preferences/UISettings.swift:25`) and `showRegulatedBadge` have no writer anywhere in the app, so both are permanently pinned at their init defaults. The icon-style branches, its Combine subscription and the badge subscription are all unreachable.

The CI5 truth fence cannot see this: it compares config-key sets and event-category sets, and these are `UISettings` properties rather than `config.toml` keys. That fence gap is worth recording in the fence's own documentation so the next reader does not over-trust it.

Fix: remove the dead plumbing, or restore the controls if either is wanted. Note `showRegulatedBadge` is read by the title logic in item 1, so land these together.

## 4. Two documented parameters that no caller ever exercises

`MeetingSourceScanner.scan(keepStickyOnEmpty:)` documents a `true` mode for when the owner is mid-recording ("a transient empty scan must not unbias the next pass", `MeetingSourceScanner.swift:51`), and the single production caller hardcodes `false`, so the documented mid-recording protection does not exist. Decide whether it should, since DET9 is touching adjacent liveness logic, then either wire it or delete the parameter and its comment.

`PromptEndPolicy`'s uncorroborated-leave-button filter has been unreachable since START1: no reachable `EndingReason` can carry `leadingSignal == ax_leave_button_invalid` with an empty `confirmedBy`, so `clearsPromptState` always returns true. Its own doc and `DetectionStateMachine`'s describe it as a live guard. Delete it or make it reachable, and fix both comments.

## 5. `PromotionEngine`'s corroboration doc names a corroborator its own rule forbids

`daemon/Sources/MeetingPipeCore/Lifecycle/PromotionEngine.swift:32-34` says a lone uncorroborated invalid is held "until a reliable signal (window-gone) corroborates", but `tick()` requires a **cross-class** corroborator and `axLeaveButton` and `shareableContentWindow` are the same class, so for a native meeting no corroborator can ever exist and that debounce path can never fire. Fix the comment, or fix the rule if the comment describes the intent.

## Scope

All five. Each is small and independent. Items 1 and 3 interact through `showRegulatedBadge`; items 4 and 5 are both detection comments and should land with or after DET9 so the wording is settled once.

## Acceptance

Suite green. No user-visible behaviour change anywhere except where item 4's `keepStickyOnEmpty` decision goes toward wiring it, which needs its own test. The `q6-final.md:76` T3 claim is corrected. The CI5 fence's documentation records what it structurally cannot see.
