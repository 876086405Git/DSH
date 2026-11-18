# Image SDK declarations for host fixtures only

These six original headers are copied byte for byte from the owner-provided
HarmonyOS SDK 26.0.0.38 input packages. Their original copyright notices and
Apache-2.0 license notices remain in each header. No SDK implementation, stub
library, runtime dependency or third-party codec implementation is included.

- Image package: `ohos-image-ndk-api26.zip`, 63,733 bytes,
  SHA-256 `8ecc46d3d1deba3f0e673ca27dc05340ddb7fc5dae933cc5fe862818c279803c`.
- Color-space package: 3,849 bytes,
  SHA-256 `9486efa811b37100e381aea5d4f739f1aefbb52fa90278e13ccf4bb383754d8b`.
- Header paths, exact sizes and SHA-256 values are in adjacent
  `../image-host-oracle.json` under `frozenTestInputs`.
- The `image-ndk-shims` sibling supplies only the previously reviewed missing
  host opaque declarations. Its required host-fixture macro prevents production
  use. The host compatibility macro removes platform availability annotations;
  this does not validate device API availability or change function types.

Only the finite host fake-SDK test includes this directory with `-isystem`.
Production SDK builds must use the actual target SDK and the independent image
build recipe. The two getter policies model alternative lifetimes; passing
both cannot establish the real SDK getter's ownership.
