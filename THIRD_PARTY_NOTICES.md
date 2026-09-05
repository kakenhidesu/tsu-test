<!-- SPDX-FileCopyrightText: 2026 Tsuyomi Contributors -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Third-party notices

Tsuyomi for iOS has no package-manager dependencies. It vendors one third-party component as source.

## QuickJS-ng 0.16.1

- Location: `Sources/CQuickJS/quickjs-ng/`
- Upstream: https://github.com/quickjs-ng/quickjs
- Licence: MIT
- Upstream source archive SHA-256: `4b3c11f37dab2c58bdeccbaeb23b923fa4a9798a45e50be6af55f3e75b616ea0`
  (recorded in `Sources/CQuickJS/quickjs-ng/UPSTREAM.md`)

The vendored files are copied verbatim and are never hand-edited; compiler diagnostics for them are
silenced with a target-scoped `-w` rather than by touching the sources. `Sources/CQuickJS/tsuyomi_quickjs_bridge.c`
and its header are Tsuyomi's own code and are licensed AGPL-3.0-only like the rest of this repository.

```
MIT License

Copyright (c) 2017-2021 Fabrice Bellard
Copyright (c) 2017-2021 Charlie Gordon
Copyright (c) 2023-2025 Ben Noordhuis
Copyright (c) 2023-2025 Saúl Ibarra Corretgé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Platform frameworks

Foundation, SwiftUI, UIKit, WebKit, CryptoKit, Compression, os and the bundled SQLite3 are Apple
platform frameworks used under the Apple SDK licence; they are linked, not vendored.
