"""Quality functions: same constants and test vectors as contract section 1."""

import numpy as np
from PIL import Image, ImageOps

from roadvis_trainer import quality as q


def gray_image(arr) -> Image.Image:
    return Image.fromarray(np.asarray(arr, dtype=np.uint8), "L")


def test_constants_match_contract():
    assert q.ANALYSIS_WIDTH == 160
    assert q.MIN_SHARPNESS == 60
    assert q.MIN_BRIGHTNESS == 35
    assert q.MAX_BRIGHTNESS == 225
    assert q.MAX_DUPLICATE_HAMMING == 6


def gradient(width=320, height=180):
    row = np.linspace(0, 255, width)
    return gray_image(np.tile(row, (height, 1)))


def test_dhash_identical_images_distance_zero():
    a = q.measure(gradient()).dhash
    b = q.measure(gradient()).dhash
    assert len(a) == 16 and int(a, 16) >= 0
    assert q.hamming(a, b) == 0


def test_dhash_mirror_of_gradient_is_far():
    img = gradient()
    a = q.measure(img).dhash
    b = q.measure(ImageOps.mirror(img)).dhash
    assert q.hamming(a, b) > 6
    # Left-dark → right-bright: no "left > right" bit set; mirrored: all 64 set.
    assert a == "0000000000000000"
    assert b == "ffffffffffffffff"


def test_dhash_bit_order_row_major_msb_first():
    # 9x8 image where only the first row decreases left→right → the top byte is 0xff.
    arr = np.zeros((8, 9))
    arr[0] = np.arange(9)[::-1] * 20
    gray = np.asarray(gray_image(arr), dtype=np.float64)
    assert q.dhash(gray) == "ff00000000000000"


def test_sharpness_flat_is_zero_and_checkerboard_high():
    flat = q.analysis_gray(gray_image(np.full((90, 160), 128)))
    assert q.sharpness(flat) == 0.0
    yy, xx = np.mgrid[0:120, 0:160]
    board = ((xx // 4 + yy // 4) % 2) * 255
    assert q.sharpness(q.analysis_gray(gray_image(board))) >= 60


def test_sharpness_is_laplacian_variance():
    arr = np.zeros((5, 5))
    arr[2, 2] = 10
    # interior 3x3 Laplacian: centre -40, its 4 neighbours +10, corners 0 → var of [0,10,0,10,-40,10,0,10,0]
    expected = np.var([0, 10, 0, 10, -40, 10, 0, 10, 0])
    assert abs(q.sharpness(arr) - expected) < 1e-9


def test_analysis_resizes_to_160_wide():
    g = q.analysis_gray(gradient(960, 540))
    assert g.shape == (90, 160)


def test_brightness_gate():
    yy, xx = np.mgrid[0:90, 0:160]
    board = ((xx // 4 + yy // 4) % 2)
    dark = q.measure(gray_image(board * 40 + 5))       # mean ≈ 25
    ok = q.measure(gray_image(board * 120 + 60))       # mean ≈ 120
    bright = q.measure(gray_image(board * 20 + 230))   # mean ≈ 240
    assert dark.brightness < 35 and dark.rejection_reason() == "tooDark"
    assert ok.rejection_reason() is None
    assert bright.brightness > 225 and bright.rejection_reason() == "tooBright"
    assert q.measure(gray_image(np.full((90, 160), 120))).rejection_reason() == "blurry"


def test_near_duplicate_threshold():
    base = "0000000000000000"
    assert q.is_near_duplicate(base, ["000000000000003f"])        # 6 bits
    assert not q.is_near_duplicate(base, ["000000000000007f"])    # 7 bits
    assert not q.is_near_duplicate(base, [])
    assert q.min_hamming(base, ["ffffffffffffffff", "0000000000000001"]) == 1
