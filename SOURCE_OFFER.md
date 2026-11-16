# Corresponding Source

This branch provides the reusable Chromium/HarmonyOS engine source mapping for
the locally validated downstream HAP with SHA-256:

`785d1dfef7adf0d07fee803401b88eb4f1c98679cfdce25e289355e615cd7327`

The corresponding source consists of:

1. Chromium revision `f043649a0ef1fd96e48d56ddbfc8a4a99aa2ca37` and the
   third-party revisions pinned by its DEPS file.
2. `patches/chromium-154-harmonyos.patch` and the 155 relocation under
   `patches/migration-155/`.
3. The complete `overlay/` and `external/` trees in this branch.
4. `config/args.plan_kirin_pc.gn` and the build instructions in `BUILDING.md`.
5. `SOURCE_MANIFEST.sha256`, which verifies every published regular file other
   than the manifest itself.

The public tree intentionally uses the generic Chromium HarmonyOS Adapter
identity. Downstream application names, artwork, signing certificates,
provisioning profiles, and private signing configuration are not included.
Distributors remain responsible for providing any additional corresponding
source required by the licenses that apply to their downstream changes.

For at least three years from 2026-08-10, recipients of that binary may request
an electronic copy of these materials through this repository's GitHub issues.
The source is provided without charge. System SDKs and standard toolchain
components are not included; obtain them from their respective vendors.
