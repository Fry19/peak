# Matching a pan: skyline stitching

A view through a window or between roofs can show too little skyline in any one frame to pin the heading down. A few degrees of a low, distant ridge fits the horizon at several headings as well as at the right one, so the matcher turns it away as ambiguous, correctly. Turning the phone shows more of the skyline, and the gyroscope knows how far it turned. Peak keeps the frames that were turned away alone and matches them together as one wider skyline.

## How it works

- **`SkylineStrip`** (`PeakCore/Sources/PeakCore/SkylineStrip.swift`) holds the skylines of up to 5 frames from the last 8 s, newest first, each with the camera it was matched with, its time, its position and its **heading by the gyroscope alone**. It drops frames from another lens, zoom (focal length more than 1% off) or way of holding the phone, frames taken more than 20 m from the newest (by the GPS fix), and older frames looking within 5% of a field of view of a newer one, since the same skyline again adds nothing. It offers the frames as views only once they reach a quarter of a field of view beyond the newest frame alone.
- **`SkylineAligner.align(_ views:…)`** matches several views at once. They share one heading correction, and each has its own pitch and roll within the usual ±1.5°/±1°. The single-frame matcher is the one-view case of the same code, and its benchmark results are unchanged. The coarse search splits by view: with the heading fixed, each view picks its own pitch and roll. Where views overlap, a point's weight is divided by the number of views that see its azimuth, so showing the same view three times weighs the same as showing it once (tested).
- **Gates.** Each gate is the single frame's, applied to all the points: candidate columns (pooled, the average share of the frames' columns), inliers, far fraction and span, ambiguity, near-ambiguity, RMS and the search edge. Inliers, far fraction and RMS count overlapping points by their share, so repeated views can't push them over. A multi-view fit must also pass two more gates. Each view refit alone, starting from the shared fit, must stay within 0.3° of the shared heading; otherwise a frame the gyroscope placed wrong pulls the shared heading toward it (see below). And every view needs at least 20 points, so each one can be checked; the result is for the newest view, which may be the bare one.
- **Each frame counts once.** `HeadingLock` waits for two agreeing matches before it moves the labels, and that only means something if the two matches come from different frames. So after any accepted match, single or stitched, the strip starts over, and the next match comes from new frames.
- **In the app**, `SkylineCorrector` matches each frame alone as before. A frame turned away joins the strip, and the strip is matched (on the matcher's utility queue). An accepted stitched result goes to `HeadingLock` like any other match, as the newest frame's correction. The diagnostics' last-match line says "N frames of a pan". The strip is cleared on pause, and work started before a pause leaves it alone. Frames from different sensor runs never mix, because the lens key includes the gyroscope's epoch.

## Gyroscope heading and its drift

Core Motion's fused attitude can't place the frames relative to each other. With a north reference frame, it keeps pulling yaw toward the magnetometer. Indoors, where stitching matters, the magnetometer is off by degrees, and by a different amount in each direction (16° at one window). `MotionTracker` therefore integrates the gyroscope's full rotation (`GyroAttitude`, rotation rate about the phone's own axes, 100 Hz) and levels it to gravity on every reading. Tipping about a level axis turns a pitched camera's heading slightly (about 0.29° per 0.5° of tilt at 30° pitch), so leveling then turns that back about the vertical, and only the gyroscope moves the camera's heading (tested at 30° pitch). The camera's gyro heading is the azimuth of the phone's −z axis. A roll about the optical axis while pitched leaves it unchanged (tested); a plain `ω·up` integral would have changed it.

The relative heading between two frames is off by roughly **bias × Δt + scale error × angle turned**:

- **Bias.** CMDeviceMotion's rotation rate is bias-corrected. A residual of 0.01–0.02°/s over the 8 s window is 0.1–0.2°.
- **Scale.** A gyroscope scale error of a fraction of a percent over a 40° pan is about 0.1–0.2°.

**Neither has been measured on a phone yet.** The next physical-device check: pan back and forth for 10 s against a distant skyline that matches alone, and compare the gyroscope's turn with the matched headings.

The shared heading turns any relative error straight into error in the result. Without the agreement gate, the pan bench (Smokies, 8° gaps) accepted a strip 1.08° off at 0.3°/s drift, and the Alps (4° gaps) one 2.2° off at 1°/s. With the gate, both were turned away ("frames disagree on the heading"). At the default 0.02°/s, no accepted strip was off by more than 0.14°. If the phone's real drift turns out larger, shorten `maxAge` rather than loosen `maxViewDisagreement`.

## Bench: `peakbench pan`

Sequences of 5 frames over a 40° pan, 1.5 s apart. Buildings stand still in the world. **Walls** reach far above the skyline, like a window frame, and leave gaps of about `--gap` degrees. **Roofs** stand just over the skyline with sky above them. The compass wanders σ 3° from frame to frame (as indoors), and the gyroscope drifts σ 0.02°/s. Each frame is matched alone (today's behavior) and then, if turned away, with the strip. There were 30 sequences per row, seed 1, with the agreement gate. "Sequences" counts the pans with at least one accepted match. "Over 0.5°" counts accepted matches that were wrong.

| Case | Sequences, single frames | Sequences, single + stitched | Stitched accepted (worst error) | Stitched over 0.5° |
|---|---|---|---|---|
| Gornergrat, walls, 4° gaps | 18 | 19 | 3 (0.10°) | 0 |
| Gornergrat, walls, 4° gaps, `--harder` | 20 | 20 | 1 (0.04°) | 0 |
| Gornergrat, roofs, 5° gaps | 2 | 2 | 0 | 0 |
| Gornergrat, no buildings, 20° lens | 22 | 22 | 0 | 0 |
| Smokies, walls, 8° gaps | 25 | 25 | 2 (0.14°) | 0 |
| Smokies, walls, 5° gaps | 20 | 21 | 2 (0.04°) | 0 |
| Smokies, walls, 8° gaps, `--harder` | 23 | 23 | 0 | 0 |
| Smokies, no buildings, 25° lens | 25 | 26 | 3 (0.04°) | 0 |
| Smokies, walls, 8° gaps, drift 0.1°/s | 25 | 25 | 1 (0.05°) | 0 |
| Smokies, walls, 8° gaps, drift 0.3°/s | 25 | 25 | 0 (1 turned away as disagreeing) | 0 |
| Smokies, walls, 8° gaps, drift 1°/s | 25 | 25 | 0 | 0 |
| Gornergrat, walls, 4° gaps, drift 1°/s | 18 | 18 | 0 (1 turned away as disagreeing) | 0 |
| Low-relief valley site in Tennessee, walls, 12° gaps | 21 | 23 | 5 (0.13°) | 0 |
| Low-relief valley site in Tennessee, walls, 8° gaps | 21 | 21 | 0 | 0 |

On a Mac, matching a strip takes about half as long as matching one frame alone (median 60–90 ms against 130–160 ms), because each frame's skyline is detected once and reused.

Single frames in the same runs had their own false acceptances: up to 27° off in the Smokies. `HeadingLock` exists to catch those, and stitching added none. The single-frame benches (`bench` in ARKit, photo and aim-any modes, `--harder`, both Smokies cases) and the saved real frames produce identical results, rejections and all, before and after the change.

### What it doesn't fix

- **Too little skyline in the gaps.** Most strips are still turned away. The 25% candidate-column gate and the far-skyline gates apply to the stitched points as a whole, and a skyline seen through 4–5° gaps every 15–20° stays under them. Each gap adds evidence, but the share of the view showing skyline doesn't grow.
- **Roofs with sky above them.** Their edges are found as skyline and match nothing, so the 40% inlier gate turns frames away alone and stitched alike.
- **Ambiguity in the terrain itself.** A low ridge that is ambiguous across the whole pan stays ambiguous. Stitching helps where the pan brings in a distinctive piece.

All of these are gates working as intended. None was relaxed.

Run it with:

```
peakbench pan --dem DEM-smokies --lat 35.654 --lon -83.444 --scene smokies --runs 30 --gap 8
peakbench pan --dem DEM --lat 45.9837 --lon 7.7856 --runs 30 --gap 4 [--harder] [--drift 0.3] [--occlusion roofs|none --fov 20]
```

## Not verified yet

The simulator has no camera or gyroscope. The app build was checked to launch, but the live path (gyroscope sign conventions in practice, real drift, how often real pans produce strips, matching time with five views) needs a physical iPhone. Saved test frames now record `frames` (1 when matched alone). `realbench` can't test stitching, because saved frames carry no gyroscope readings and are taken minutes apart.
