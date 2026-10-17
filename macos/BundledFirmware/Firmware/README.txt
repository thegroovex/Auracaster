Auracaster dongle/repeater firmware bundled into the app (Contents/Resources/Firmware).

The CI copies the freshly built auracaster-*.uf2, SHA256SUMS.txt and
firmware-manifest.json here before building the app (.github/workflows/auracaster-macos.yml,
job "firmware" -> "build"). Local Xcode builds without these files still work: the
dongle assistant then downloads the firmware from the latest GitHub release.
