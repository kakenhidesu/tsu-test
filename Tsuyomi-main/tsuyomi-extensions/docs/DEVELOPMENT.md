<!-- SPDX-FileCopyrightText: 2026 Tsuyomi Contributors -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Extension development contract

## Package layout

```text
extension.hxp
├── manifest.json        # canonical manifest and integrity.files map
├── index.mjs
├── assets/
├── locales/
└── signature.ed25519    # detached Ed25519 signature of canonical manifest.json
```

`integrity.files` MUST contain every archive entry other than `manifest.json` and
`signature.ed25519`; excluding those two avoids an impossible manifest self-digest. The detached
signature authenticates the manifest and its integrity map.

## Rules

1. Declare every network origin before use; HTTP is forbidden unless a future protocol version names an exceptional migration path.
2. Treat cookies as host-managed, source-scoped state. An extension cannot enumerate or export them.
3. Request Web login only when the source requires user authentication or verification. The host opens a controlled view; no automation bypasses CAPTCHAs, Cloudflare, or similar controls.
4. Store only small source-local durable state through the quota-bound host storage API.
5. Declare every supported remote-library write operation. Network access alone never authorizes `add`, `remove`, or `move`; writeback remains disabled until the user grants the capability and enables it for that source.
6. Extensions receive no device model, display-profile, panel-refresh, Compose, or Android rendering API. Their results must be presentation-neutral and must not require animation, color-only meaning, infinite scroll, pull-to-refresh, or a swipe-only action.
7. Test against sanitized fixtures. Do not commit credentials, raw session data, copyrighted chapter payloads, or live-site test dependencies.

The Host API and package contract are versioned external interfaces. This repository encodes each extension's compatible Host API range but deliberately has no relative-path dependency on a host or protocol checkout; consumers must bind a reviewed protocol revision independently.

## Production packaging and repository metadata

After compiling this checkout, `npm run release:prepare -- --revision <40-lowercase-hex-commit> --output <release-input.json>` reads the reviewed `release/sources.json` configuration and emits a canonical `tsuyomi-release-input` v1 bundle. The bundle carries the complete HXP manifest template, canonical base64 compiled files, language/license metadata, and any reviewed legacy migration binding. It has no integrity map, signature, private key, network activity, or executable packaging step. The protected publisher workflow replaces the neutral configured-publisher `keyId`, then uses the existing HXP packager and catalog generator from its pinned signing-tool checkout.

`npm run package:hxp -- --help` is the explicit local/manual-import path for a production HXP: it requires supplied archive files, a complete manifest template (except generated integrity), and a custodian-owned Ed25519 PKCS#8 key. It validates the completed manifest using the pinned Apache-2.0 `schemas/hxp-manifest-v1.schema.json` recorded with an exact source/blob/content hash in `EXTRACTION_PROVENANCE.md`, then applies Android's additional capability-policy semantics (origin containment, operation/method pairing, and remote parameter requirements); it has no default key and rejects the deterministic fixture public key. It also rejects files/manifest/archive sizes outside the Android verifier's 8 MiB/128 KiB/16 MiB limits and more than 256 archive entries. A manually imported HXP is not a published release, and running this command does not authorize catalog publication.

The catalog generator derives publisher fingerprints from raw base64 Ed25519 public keys and rejects duplicate JSON keys, unsupported fields, Android-incompatible SemVer values, oversized catalogs, ambiguous identifiers, invalid revision/digest formats, and raw non-HTTPS credential/fragment URI input. It canonicalizes accepted package URLs to the exact ASCII strings it signs. See the root README for command and input examples.

## Deterministic Wenku8 update fixture

`update-check-v2` is a signed read-only capability, not a directory-transport fallback. Its source export must build only the exact manifest-declared `NETWORK_ONLY` GET. It emits `{ complete: true, order: "source" }` only after confirming a closed HTML envelope, exactly one balanced canonical directory table (inside static `#list`, or the dynamic page's standalone `table.css`), matching book chapter evidence, and no continuation page; it parses only that table, excluding unrelated page links. Missing, truncated, ambiguous or noncanonical tables fail closed. Ordinary directory parsing remains deliberately more permissive. The update export must never emit a chapter URL, raw chapter text, HTML, credentials, or a source-controlled anchor. Anchors bind source/book/ordered chapter IDs; titles are display metadata and title corrections do not fabricate an order change.

After changing source or manifest code, run `npm test`; contributor CI independently runs `npm run package:fixture` to generate its AGPL test artifact. That artifact is test-only, has no production-signing role, and its regenerated binary or SHA file does not need to be committed merely for CI. The pinned historical host replay fixture is never regenerated or altered. Do not record a volatile fixture digest as release identity; production publication binds the reviewed release-input bundle to the compiled source revision instead.

Wenku8 is the first vertical slice: install → grant → optional deliberate login/verification → search → detail → directory → chapter → locator/progress. Library organization and remote-library writes remain outside Phase 2.
