# Face ID components

IVY's Face ID is adapted from **Glance** by Jonathan Zhou (MIT License),
https://github.com/jonnyoo/glance — the Vision → 5-point alignment → ArcFace
pipeline, match thresholds, liveness cues, lock-screen password typing and the
lock-screen window technique. IVY's code is a rewrite for this project; the
notch UI and animations are IVY's own.

```
MIT License

Copyright (c) 2026 Jonathan Zhou

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

## ArcFace model

`IVY/IVY/Resources/FaceID/ArcFace.mlpackage` is Glance's Core ML conversion of
InsightFace's `w600k_mbf` recognition model (buffalo_s pack, MobileFaceNet
backbone, ArcFace loss). Input `input_image` (112×112 RGB), output `embedding`
(512 floats). SHA-256 of `weight.bin`:
`994e849b8fd0d44dbb33b4aac42d1e0b49b8410ede0f9d32b93ae5d827ed6e68`.

**License caveat:** InsightFace's code is MIT, but its pretrained model weights
are provided for **non-commercial research purposes only**
(https://github.com/deepinsight/insightface#license). The weights are not
covered by IVY's MIT license. Commercial distribution needs a license from
InsightFace or a replacement model with the same contract.

## SkyLight lock-screen window

`SkyLightSpace` (in `IVY/IVY/Core/FaceID/LockScreen.swift`) is adapted from
Lakr233/SkyLightWindow (MIT), https://github.com/Lakr233/SkyLightWindow, via
Glance. It calls private SkyLight symbols and fails gracefully if they are
missing.
