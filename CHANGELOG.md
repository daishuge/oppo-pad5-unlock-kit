# Changelog

## 0.1.0-preview.1 - 2026-08-29

Initial public Preview.

- Added an exact-identity, physically read-only OPD2506 checker.
- Added pinned asset validation with atomic promotion.
- Added a fail-closed B-to-A state machine and planning-only advanced launcher.
- Added inactive-slot read-only verification and a single guarded LK write boundary.
- Added mock coverage for false fastboot success, slot/battery drift, hash/size mismatch, interrupted write readback, state drift, Unicode paths, and PowerShell 7/5.1 behavior.
- Documented the evidence boundary: the historic manual path has single-device evidence; the new destructive automation has no new real-device execution evidence.
