#!/usr/bin/env python3
"""
Renders Humdrum's app icon as an .iconset folder of PNGs.

The icon is an emerald AudioVisualizer orb centered on a dark squircle
background — the same look as the in-app launch logo, sized to macOS
Big Sur+ icon proportions (content occupies ~82% of the canvas with
Apple's superellipse corner so it reads as a "real Mac app icon" in
Finder / Dock / Launchpad).

Why opaque instead of transparent:
  - A transparent icon disappears into the Dock wallpaper and looks
    half-finished next to every other app.
  - Dark Mode dock shows light icons better; Light Mode dock shows
    dark icons better. A dark squircle with a bright emerald orb
    reads well in both.
  - The in-app logo already uses this same dark-squircle-plus-orb
    style, so the Dock → About-window transition feels continuous.

We draw everything procedurally with NumPy so we don't need SVG tooling
or CoreGraphics — just Pillow + NumPy. Output is macOS's standard
iconset layout; `iconutil -c icns` produces the final .icns from it
at build time (see build-app.sh).

Layers, inner to outer:
  0. Dark squircle base (superellipse, near-black with a subtle
     emerald-tinted top-down gradient)
  1. Deep emerald core
  2. Main sphere body — radial gradient from emerald → teal → edge
  3. Specular highlight — small, offset upper-left, near-white
  4. Outer halo — soft bloom over the squircle

The outer transparent margin around the squircle is kept narrow
(~9% per side) so macOS's own shadow/halo still sits where Apple
expects it to.
"""
from __future__ import annotations

import math
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image


# --- Palette ----------------------------------------------------------
# Tuned to look like the visualizer's resting hue (drifts green↔teal).
# Values are 0..1 linear RGB picked from HSB analogous to the Swift
# palette at hue ≈ 0.40 (emerald with a faint teal lean):
#
#   accent (hue 0.40, sat 0.95, bri 0.96) → #0CF49A-ish
#   hot    (hue 0.40, sat 0.55, bri 1.00) → lighter, desaturated
#   deep   (hue 0.40, sat 0.92, bri 0.62) → darker shadow color
#
EMERALD_ACCENT = np.array([0.05, 0.95, 0.58])   # main tint
EMERALD_HOT    = np.array([0.50, 1.00, 0.85])   # bright highlight
EMERALD_DEEP   = np.array([0.02, 0.45, 0.30])   # shadow side
CORE_WHITE     = np.array([0.95, 1.00, 0.98])   # specular core

# --- Squircle background ---------------------------------------------
# Near-black with a faint emerald lift at the top so the icon reads as
# "from the Humdrum family" rather than a generic black square.
# Matches the in-app logo's squircle fill.
SQUIRCLE_TOP    = np.array([0.06, 0.10, 0.09])  # ~#10191
SQUIRCLE_BOTTOM = np.array([0.02, 0.03, 0.03])  # near-black
# Apple's macOS app-icon canvas convention: content occupies ~82% of
# the image with ~9% padding on each side. We follow the same ratio.
CONTENT_FRACTION = 0.824
# Apple's icon shape is a superellipse (|x/a|^n + |y/a|^n = 1) with
# n ≈ 5. Slightly softer than a rounded-rect, slightly firmer than
# a circle — the "squircle" shape you see across Sonoma/Sequoia.
SQUIRCLE_N = 5.0


def _smoothstep(edge0, edge1, x):
    """
    Standard GLSL-style smoothstep — 0 when x<=edge0, 1 when x>=edge1,
    smooth hermite in between. Requires edge0 < edge1; for a reversed
    ramp (1 when below, 0 when above), compute `1 - smoothstep(a, b, x)`
    rather than flipping the edges (the old version silently clamped
    the denominator and produced an inverted mask, which cost me a
    morning).
    """
    if edge0 >= edge1:
        raise ValueError(f"_smoothstep requires edge0 < edge1, got {edge0}, {edge1}")
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def render_icon(size: int) -> Image.Image:
    """Render the orb icon at `size` × `size`. Returns an RGBA PIL Image."""
    # Draw at 2× internal resolution then downsample with LANCZOS. Keeps
    # small sizes (16, 32) readable without muddy gradient banding.
    ss = 2 if size <= 128 else 1
    w = size * ss

    # Coordinates normalized so r=1.0 sits at the sphere's visible edge.
    # The sphere is slightly smaller than before so it has room to
    # breathe inside the squircle — previous layout filled ~62% of the
    # full canvas, now ~52% of the canvas (~63% of the squircle interior).
    yy, xx = np.mgrid[0:w, 0:w].astype(np.float32)
    cx = cy = (w - 1) / 2.0
    sphere_radius_px = w * 0.26           # sphere edge
    dx = (xx - cx) / sphere_radius_px
    dy = (yy - cy) / sphere_radius_px
    r = np.sqrt(dx * dx + dy * dy)

    # We build up (rgb, alpha) in straight (non-premultiplied) space
    # using a tiny local compositor. Each layer is "src over dst".
    rgb = np.zeros((w, w, 3), dtype=np.float32)
    alpha = np.zeros((w, w), dtype=np.float32)

    # ---- 0. Dark squircle background --------------------------------
    # Superellipse mask: |x/a|^n + |y/a|^n <= 1. `a` is the half-extent
    # in pixels based on CONTENT_FRACTION; we build a small smoothstep
    # around the boundary for antialiasing. Then fill with a vertical
    # emerald-to-near-black gradient so the squircle has quiet depth
    # instead of looking flat and plastic.
    sq_half = (w * CONTENT_FRACTION) / 2.0
    sx = (xx - cx) / sq_half
    sy = (yy - cy) / sq_half
    sq_r = (np.abs(sx) ** SQUIRCLE_N + np.abs(sy) ** SQUIRCLE_N) ** (1.0 / SQUIRCLE_N)
    # Edge AA scaled to pixel width so it stays a ~1 px transition at
    # every size, not a blurrier one at large canvases.
    aa = 1.5 / sq_half
    squircle_mask = 1.0 - _smoothstep(1.0 - aa, 1.0 + aa, sq_r)

    # Vertical gradient from SQUIRCLE_TOP at the top of the canvas
    # to SQUIRCLE_BOTTOM at the bottom. Clipped to [0, 1] on the
    # normalized y so it lines up with the squircle bounds.
    ty = np.clip((yy / (w - 1)), 0.0, 1.0)[..., None]
    squircle_rgb = SQUIRCLE_TOP * (1.0 - ty) + SQUIRCLE_BOTTOM * ty
    _src_over(rgb, alpha, squircle_rgb, squircle_mask)

    # Mask that's 1 strictly inside the sphere, 0 outside, with a
    # narrow smoothstep over the rim for antialiasing. Computed up
    # front because both the body layer and the halo use it.
    body_mask = 1.0 - _smoothstep(0.985, 1.01, r)

    # ---- 1. Outer halo bloom -----------------------------------------
    # Soft emerald glow that lives OUTSIDE the sphere and fades to
    # fully transparent well before the canvas edge. Gaussian in
    # (r - 1), gated by (1 - body_mask) so the gaussian's peak-at-r=1
    # value doesn't bleed into the sphere interior.
    halo_t = np.maximum(r - 1.0, 0.0)
    halo_intensity = np.exp(-(halo_t * 3.2) ** 2) * (1.0 - body_mask)
    halo_rgb = EMERALD_ACCENT * 0.75 + EMERALD_HOT * 0.25
    _src_over(rgb, alpha, halo_rgb, halo_intensity * 0.55)

    # ---- 2. Sphere body (base emerald gradient) ----------------------
    # Smooth radial lerp from a bright inner mix (accent + a pinch of
    # hot) to the deep edge tone. Single lerp = no "dark dot" artifact
    # in the middle where three clipped contributions would collide.
    t = np.clip(r, 0.0, 1.0)
    inner = EMERALD_ACCENT * 0.85 + EMERALD_HOT * 0.30     # bright core tone
    outer = EMERALD_DEEP                                    # dim rim
    # t**1.5 biases the gradient slightly toward the edge, which keeps
    # the sphere's "face" bright across most of its area and confines
    # the dark shading to the outer ~25%.
    shade = (t ** 1.5)[..., None]
    body_rgb = np.clip(inner * (1.0 - shade) + outer * shade, 0.0, 1.0)
    _src_over(rgb, alpha, body_rgb, body_mask)

    # ---- 3. Specular highlight ---------------------------------------
    # Small bright blob offset upper-left, like sunlight on a glass
    # marble. Additively brightens the body (masked so it never leaks
    # past the rim). Not full white — a warm almost-white so it reads
    # as part of the emerald family.
    ox, oy = -0.42, -0.48
    hr = np.sqrt((dx - ox) ** 2 + (dy - oy) ** 2)
    spec = np.exp(-(hr * 3.5) ** 2) * body_mask
    _add_rgb(rgb, CORE_WHITE,  spec * 0.55)
    _add_rgb(rgb, EMERALD_HOT, spec * 0.35)

    # ---- 4. Broader upper-hemisphere glow ----------------------------
    # Subtle second highlight giving the upper half of the sphere extra
    # luminosity — sells the 3D feel at a glance.
    ox2, oy2 = -0.15, -0.30
    hr2 = np.sqrt((dx - ox2) ** 2 + (dy - oy2) ** 2)
    upper = np.exp(-(hr2 * 1.3) ** 2) * body_mask
    _add_rgb(rgb, EMERALD_HOT, upper * 0.18)

    # ---- Finalize -----------------------------------------------------
    rgb = np.clip(rgb, 0.0, 1.0)
    alpha = np.clip(alpha, 0.0, 1.0)

    rgba = np.empty((w, w, 4), dtype=np.uint8)
    rgba[..., 0] = (rgb[..., 0] * 255.0).astype(np.uint8)
    rgba[..., 1] = (rgb[..., 1] * 255.0).astype(np.uint8)
    rgba[..., 2] = (rgb[..., 2] * 255.0).astype(np.uint8)
    rgba[..., 3] = (alpha       * 255.0).astype(np.uint8)

    img = Image.fromarray(rgba, mode="RGBA")
    if ss != 1:
        img = img.resize((size, size), Image.LANCZOS)
    return img


def _src_over(dst_rgb, dst_a, src_rgb, src_a):
    """
    Straight 'src over dst' alpha compositing, operating in place.
    `src_rgb` is a constant (H,W,3) or broadcastable color; `src_a`
    is an (H,W) alpha mask. Uses the textbook straight-alpha formula:
        out_a   = src_a + dst_a * (1 - src_a)
        out_rgb = (src_rgb * src_a + dst_rgb * dst_a * (1 - src_a)) / out_a
    Guarded so zero-alpha pixels don't blow up in the divide.
    """
    src_a3 = src_a[..., None]
    out_a = src_a + dst_a * (1.0 - src_a)
    numer = src_rgb * src_a3 + dst_rgb * (dst_a[..., None]) * (1.0 - src_a3)
    denom = np.maximum(out_a[..., None], 1e-6)
    dst_rgb[:] = numer / denom
    dst_a[:]   = out_a


def _add_rgb(dst_rgb, color, mask):
    """Additive RGB bump inside an existing alpha region — used for
    highlights so they brighten the body rather than punch through to
    the background. Mask acts as the strength; alpha is untouched."""
    dst_rgb[:] = np.clip(dst_rgb + color * mask[..., None], 0.0, 1.0)


# Iconset entries required for macOS AppIcon.icns. Each is
# (base_size, scale, filename_suffix). iconutil reads this layout.
ICONSET_ENTRIES = [
    (16,   1, "icon_16x16.png"),
    (16,   2, "icon_16x16@2x.png"),
    (32,   1, "icon_32x32.png"),
    (32,   2, "icon_32x32@2x.png"),
    (128,  1, "icon_128x128.png"),
    (128,  2, "icon_128x128@2x.png"),
    (256,  1, "icon_256x256.png"),
    (256,  2, "icon_256x256@2x.png"),
    (512,  1, "icon_512x512.png"),
    (512,  2, "icon_512x512@2x.png"),
]


def main(out_dir: str) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    rendered: dict[int, Image.Image] = {}
    for base, scale, name in ICONSET_ENTRIES:
        pixels = base * scale
        if pixels not in rendered:
            print(f"  render {pixels}×{pixels}")
            rendered[pixels] = render_icon(pixels)
        rendered[pixels].save(out / name, "PNG", optimize=True)
    print(f"  wrote {len(ICONSET_ENTRIES)} PNGs → {out}")


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.iconset"
    print(f"==> Generating Humdrum app icon → {target}")
    main(target)
