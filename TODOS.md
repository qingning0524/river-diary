# River Diary TODOs

## P1

### Key recovery and rotation for encrypted local evidence

- **What:** Design and implement explicit key recovery/rotation for the SQLCipher legacy and V2 stores, including cross-device transfer, lost-key UX, backup key wrapping, and safe re-encryption.
- **Why:** The local databases are now encrypted and migrated safely, but the key is currently local-only; losing `journal-encryption.key` makes the database unrecoverable.
- **Pros:** Makes the private fact store recoverable across Mac replacement and future phone/Windows/web clients.
- **Cons:** Adds a high-risk recovery secret and migration flow; must not reintroduce startup password prompts or expose keys in logs/backups.
- **Context:** SQLCipher 4.19.0 is embedded and licensed; tests cover database/WAL plaintext leakage, wrong keys, old-library migration, interrupted migration, encrypted snapshots, and full backup restore. Preserve no-password-prompt startup behavior.
- **Depends on / blocked by:** An explicit user-approved recovery design and cross-device trust model.

### External 7-day validation

- **What:** Recruit 3 Mac-heavy students or independent developers and observe them using River Diary for 7 days.
- **Why:** The product currently has one real user; external demand, trust, retention, and willingness to return are unverified.
- **Pros:** Validates the daily report, Evidence Inbox, Daily Review, and natural-language query before the product expands into sync and more data sources.
- **Cons:** Requires recruitment, sanitized test data, observation notes, and a week of follow-through.
- **Context:** Give each participant two unassisted tasks: review yesterday and ask one natural-language question; record trust failures, corrections, missing sources, and next-day return behavior without leading with the personal OS vision.
- **Effort:** Human 1–2 weeks → CC+gstack ~30 minutes for instrumentation and analysis.
- **Depends on / blocked by:** Phase 1 Today Dashboard, left-navigation DateContext, minimal evidence query, and source-health status.

## P2

### Production encrypted sync

- **What:** Implement end-to-end encrypted sync across Mac, iPhone, Windows, and web with key recovery, conflict resolution, deletion propagation, export, and old-client compatibility.
- **Why:** Cross-device memory is part of the long-term Personal Evidence OS, but it should not block local-first validation.
- **Pros:** Extends one fact store across devices while preserving user ownership and model portability.
- **Cons:** Adds server, cryptography, recovery, migration, billing, and multi-client testing complexity.
- **Context:** Start only after the three-layer fact contract, versioned evidence schema, export/delete semantics, and external users demonstrate real cross-device demand.
- **Effort:** Human 1–2 months → CC+gstack ~1–2 hours for an initial implementation pass.
- **Priority:** P2.
- **Depends on / blocked by:** External validation, stable local fact/evidence model, source-health semantics, and an explicit recovery design.
