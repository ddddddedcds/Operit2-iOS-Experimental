# Third-Party Software Acknowledgements / 第三方组件致谢

Operit2 (iOS, rootless) integrates the following third-party open-source
components. We are grateful to their authors.

## Used packages / 所用包（附 GitHub 地址，均未遗漏）

- **ElleKit** — rootless tweak injection libraries & loader (by opa334)
  https://github.com/opa334/ElleKit
  Used as the runtime hooking substrate for the SpringBoard control tweak and
  per-app dylib injection. Declared as a package dependency (`ellekit`).

- **ios-mcp** — MCP server for AI-driven iOS device control (by witchan)
  https://github.com/witchan/ios-mcp
  Operit2's screenshot, OCR, touch/input and device-automation layer is
  delegated to the ios-mcp backend running on the device (localhost:8090).
  Declared as a package dependency (`com.witchan.ios-mcp`).

(The bundled Operit2 Flutter app also statically embeds the Flutter engine,
the Dart runtime, and Python scientific frameworks (NumPy/SciPy). Their
respective licenses are available in their upstream projects.)

## Acknowledgements (感谢)

Special thanks to **opa334** for **ElleKit**, the rootless hooking substrate
that makes this tweak possible, and to **witchan** for **ios-mcp**, whose
device-control MCP server powers Operit2's screenshot / OCR / automation
layer. Operit2 would not function without these excellent open-source
components.

---

## ElleKit license (BSD 3-Clause)

Copyright (c) 2022 Évelyne Bélanger All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
  * Neither ElleKit nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

---

## ios-mcp license (MIT)

MIT License

Copyright (c) 2026 witchan

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
