# ADR 0006: Swift over Go for the eventual two-Mac Hub

| Property            | Value              |
| ------------------- | ------------------ |
| **Status**          | Proposed           |
| **Date**            | 2026-05-18         |
| **Decision Makers** | Project owner      |
| **Technical Area**  | Hub / sync         |
| **Related Tasks**   | TECH-G1            |

## Context

The Q2 backlog calls for a personal two-Mac Hub (TECH-G1) so the user's
home Mac and work Mac share one library. The Hub is single-user,
two-machine, no multi-tenant, no external sharing. Earlier discussion
floated a self-hosted helper daemon written in Go that would run on a
home NAS or VPS and act as the sync target. The current backlog
recommends CloudKit private database instead, with no self-hosted
helper. If the self-hosted helper is ever revisited, the question of
language reopens.

## Decision Drivers

- **One language across the codebase.** The daemon is Swift. Adding Go
  means a second toolchain, a second test runner, a second CI matrix,
  and a second set of conventions to maintain.
- **CryptoKit + AppleKeyChain access.** The Hub's encryption layer
  (TECH-G1) holds the passphrase-derived key in the iCloud Keychain.
  Swift has first-class access; Go would need a CGo bridge or a
  separate keychain binary.
- **CloudKit Swift SDK.** If the chosen backend is CloudKit (per
  TECH-G1's recommendation), the SDK is Swift-only outside of
  REST-API workarounds.
- **Self-hosted helper is currently not on the path.** The question is
  only live if the user later wants a NAS-resident sync target. In
  that scenario, the helper still needs to read and write the same
  encrypted blobs the daemon reads and writes; sharing the encryption
  and schema code in one language matters more than picking the
  trendier server-side language.

## Options Considered

### Option A: Go for any self-hosted helper

Pros: small static binaries, good for a NAS or VPS deployment; mature
HTTP and storage libraries. Cons: encryption layer has to be
reimplemented in Go and kept in sync with the Swift daemon; CGo
bridges add their own failure modes.

### Option B: Swift for any self-hosted helper

Pros: shares the daemon's encryption, schema, and conflict-resolution
code directly; one toolchain. Cons: Linux Swift is supported but the
ecosystem is smaller than Go's; deploying to a NAS or VPS requires a
Linux-compatible Swift toolchain.

### Option C: Defer the question; commit to CloudKit private database (no helper)

Pros: zero server to operate; end-to-end encryption to the iCloud
Keychain; no language question. Cons: tied to Apple's CloudKit
service; if Apple ever changes private-database pricing or quotas,
the user has no fallback besides reopening the helper question.

## Decision

**Option C is the working plan. If a self-hosted helper is ever
revisited, Option B (Swift on Linux) wins by default.** The trigger to
revisit is "CloudKit limits become a real constraint for the
single-user two-machine setup" or "the user wants to share with a
second person, which redesigns the Hub anyway."

The reasoning for choosing Swift over Go in the hypothetical helper
scenario: the helper is not a general-purpose service. It is a sync
target for one codebase that is already in Swift. Reimplementing the
encryption and conflict-resolution logic in Go means maintaining two
implementations of the same contract, and that cost dominates any
ergonomics win from Go's standard library.

## Consequences

- TECH-G1 ships against CloudKit private database. No helper code is
  written.
- If the helper question reopens, the Hub's encryption layer
  (`Encryption.swift`) and conflict resolver (`ConflictResolver.swift`)
  are designed to be shareable with a Linux Swift target without
  AppKit imports.
- The `Sources/MeetingPipe/Hub/` files do not import AppKit unless
  strictly required; this keeps the future-portability option open
  without affecting current development.
- Go is not added to the toolchain matrix unless and until the helper
  question reopens with a Go-specific reason that overrides the
  language-consistency argument above.
