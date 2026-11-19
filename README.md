# Sorot

A menu bar app for macOS that turns the edges of your screen into a light for your webcam, and adjusts that light by itself.

It watches your face through the camera, measures how bright it is, and raises or lowers a band of light around the screen until your face reaches the brightness you set. It also estimates the colour of the light in your room and tints the screen light to match, so your face is not lit in two different colours.

*Sorot* is Indonesian for a beam of light.

<img src="docs/panel-dark.png" alt="The Sorot menu bar panel: face brightness, room colour temperature and glow level, with sliders for target brightness and reach" width="300">

Status: v0.3, an early prototype. The control loop is rule-based, the probe measures the room's light colour directly, and a small model inside the app learns from those probes. The learner has been checked on simulated data only, not yet on a real camera.

## Why I built this

I live in Indonesia. As I write this, in November 2026, smoke from forest and land fires (*kebakaran hutan dan lahan*, or *karhutla*) hangs over where I live, and my classes have moved to Zoom.

Haze does two things to the light in a room. It makes daylight weaker, and it turns it yellow-orange. On camera that gives you a dark face in an odd colour, and it can change through the day as the smoke thickens and clears.

Those are the two things Sorot measures and corrects: how bright your face is, and what colour the light in your room is. It uses the laptop screen because that is the one light everyone in an online class already has in front of their face.

A few of my friends and I use it for our online classes.

## How it works

About five times a second:

1. **Capture.** One 640×480 frame from the default camera.
2. **Find the person.** Two of Apple's Vision models run on the frame: a face detector, and a person segmenter that separates you from the room.
3. **Measure.** Average brightness of the middle of your face, the left and right halves separately, and the average colour of the background.
4. **Estimate the room.** The background colour is converted to a colour temperature in kelvin (McCamy's approximation).
5. **Decide.** If your face is darker than the target, the glow goes up; if brighter, down. Inside a small band around the target nothing changes, which stops flicker.
6. **Light.** The band on each screen edge is redrawn. The edge next to the brighter side of your face is dimmed, which evens out side shadows.

In manual mode the camera is off and you set brightness and colour yourself.

## The probe

The camera white-balances every frame before any app sees it, so a frame alone cannot show what colour the room's light really is. The probe gets around that by running a small experiment with the one light the app controls.

For about a second the screen edges go solid black, then solid white, at the widest band whatever Reach is set to. Sorot measures your face in both states:

    dark face  =  camera gains × skin × room light
    lit face   =  camera gains × skin × (room light + screen white)

Dividing the first by the difference of the two cancels both your skin colour and the camera's gains, and leaves the room light's colour relative to the screen's white. If the camera changes its exposure or white balance between the two states, the background shows it (the pulse is too weak to reach the far wall), and Sorot divides that change out.

The result corrects the picture-based estimate until the next probe. You can probe by hand or every five minutes. `Sorot --selftest` checks the maths against simulated cameras.

The probe fails, and says so, when the pulse makes no measurable difference to your face (the room is too bright, or you sit too far from the screen), when no background is in view, or when your face leaves the frame.

## The learner

A probe is accurate but it flashes the screen, so you do not want one every minute. The learner makes each probe count for longer.

Every successful probe gives one example: what the camera saw just before it, and how far the picture-based estimate was from the truth. The app keeps those examples and fits a small model to them (ridge regression on eight numbers: the picture estimate, the colour of the background and of your face, the brightness of your face and of the frame, and the glow level). Between probes the model predicts the correction from the current frame, so the Room reading follows the light as it changes.

It trains itself, on your Mac, with no setup:

- It is refitted from scratch after every probe. With 300 probes that takes about 0.15 ms, and one prediction takes under a microsecond.
- It is not used until it has at least 8 probes and predicts probes left out of its fit better than a constant correction does. Until then the last probe's correction is used, as before.
- The panel says which is in use, and gives the model's typical error on left-out probes.
- It keeps the newest 300 probes, so it follows a new room or camera as old examples drop out.

`Sorot --selftest` checks it on made-up data: it learns a made-up camera's error from 12 probes, and it refuses to trust itself when the data is only noise.

## Install

Needs macOS 13 or later. Works on Apple silicon and Intel Macs.

1. Download `Sorot-0.3.0.zip` from the [latest release](https://github.com/malkamericanooo/sorot/releases/latest) and double-click it.
2. Drag `Sorot.app` into your Applications folder.
3. Open it. macOS will refuse the first time, because Sorot is not signed by a paid Apple developer account. Click **Done** (or **OK**).
4. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the line about Sorot. Confirm.
5. Sorot appears in the menu bar. Switch it on and allow camera access.

You only do steps 3 and 4 once. If you would rather not trust a download, build it yourself from the source below; it is the same code.

## Build

Needs macOS 13 or later and Xcode's command line tools.

```bash
./make-app.sh
open build/Sorot.app
```

The app appears in the menu bar. It starts switched off. The first time you switch it on, macOS asks for camera access.

`./make-release.sh` builds the download: one app for both kinds of Mac, signed ad-hoc and zipped.

`make-app.sh` signs the app with your Apple Development certificate if you have one. Without one the signature is ad-hoc, and macOS asks for camera access again after every rebuild.

## Privacy

Frames are analysed in memory on your Mac and then discarded. Nothing is uploaded.

The learner keeps nine numbers and the time for each probe (the eight above and the probe's answer) in `~/Library/Application Support/Sorot/learner.json`. Delete that file to make it forget.

"Save probe data" is off by default. When on, each probe appends one line to `~/Library/Application Support/Sorot/probes.jsonl`: the probe's measurements and two colour histograms of the frame. The histograms count how many pixels had each colour and keep no positions, so no picture can be rebuilt from them.

The camera's green light stays on while automatic mode is running, because the app is reading the camera.

## Limits

- A screen is a weak light. It helps in a dim room at laptop distance and does very little in daylight. In one test in a daylit room with a bright background, full glow at full Reach did not raise the measured face brightness at all (27% with the glow off, 25% with it on, the difference being the camera's own drift). Sorot says so in its status line when it is at full glow and the light behind you is stronger than the screen.
- When full glow has not brought your face to the target for 8 seconds, Sorot probes once by itself (at most every five minutes). If the probe shows the screen makes no difference, the glow switches off and rests until you probe again, switch the light off and on, or the room gets clearly darker. A camera that brightens its picture as the room darkens can hide that last change, so the glow may stay resting after dusk until you probe.
- `Sorot --diagnose <file>` repeats that test on your Mac: it measures your face with the glow off, at Reach 20% and at Reach 100%, and writes the numbers and a 32×24 grid of brightness digits to the file. It saves no image.
- Without a probe, the room colour is estimated from the background of frames the camera has already white-balanced, assuming the background averages out to grey. Treat that number as approximate.
- The probe assumes the screen's white is neutral. Night Shift and True Tone tint the screen, which shifts its reading.
- The probe assumes the pulse does not reach the background. With a wall close behind you it does: in simulation, 10% of the pulse reaching the wall moved a 2900 K reading by about 170 K.
- The probe has been checked in simulation. It has not yet been checked against a lamp of known colour temperature.
- The learner is only as right as the probes it learns from, so every probe limit above is also a learner limit. Its model is a straight-line fit, and it has not yet been tested on real probes.
- One brightness target does not suit every skin tone. Set "Target brightness" to what looks right for you.
- The light covers the screen edges. "Reach" sets how far in it goes. Clicks pass through it, and a band fades out while the pointer is inside it, but anything under a band is hidden the rest of the time.
- Only the main display is lit.

## Roadmap

- **v0.4** Measure the learner on real probes across different rooms and lamps, and publish the error. Try a model that reads the saved colour histograms and compare the two.
- **v1.0** Signed release.

## Licence

MIT. See [LICENSE](LICENSE).
