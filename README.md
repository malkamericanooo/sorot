# Sorot

A menu bar app for macOS that turns the edges of your screen into a light for your webcam, and adjusts that light by itself.

It watches your face through the camera, measures how bright it is, and raises or lowers a band of light around the screen until your face reaches the brightness you set. It also estimates the colour of the light in your room and tints the screen light to match, so your face is not lit in two different colours.

*Sorot* is Indonesian for a beam of light.

<img src="docs/panel-dark.png" alt="The Sorot menu bar panel: face brightness, room colour temperature and glow level, with sliders for target brightness and reach" width="300">

Status: v0.2, an early prototype. The control loop is rule-based, and the probe measures the room's light colour directly. The trained colour model described under Roadmap does not exist yet.

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

For about a second the screen edges go solid black, then solid white. Sorot measures your face in both states:

    dark face  =  camera gains × skin × room light
    lit face   =  camera gains × skin × (room light + screen white)

Dividing the first by the difference of the two cancels both your skin colour and the camera's gains, and leaves the room light's colour relative to the screen's white. If the camera changes its exposure or white balance between the two states, the background shows it (the pulse is too weak to reach the far wall), and Sorot divides that change out.

The result corrects the picture-based estimate until the next probe. You can probe by hand or every five minutes. `Sorot --selftest` checks the maths against simulated cameras.

The probe fails, and says so, when the room is too bright for the screen to make a measurable difference, when no background is in view, or when your face leaves the frame.

## Build

Needs macOS 13 or later and Xcode's command line tools.

```bash
./make-app.sh
open build/Sorot.app
```

The app appears in the menu bar. It starts switched off. The first time you switch it on, macOS asks for camera access.

## Privacy

Frames are analysed in memory on your Mac and then discarded. Nothing is uploaded. "Save probe data" is off by default. When on, each probe appends one line to `~/Library/Application Support/Sorot/probes.jsonl`: the probe's measurements and two colour histograms of the frame. The histograms count how many pixels had each colour and keep no positions, so no picture can be rebuilt from them.

The camera's green light stays on while automatic mode is running, because the app is reading the camera.

## Limits

- A screen is a weak light. It helps in a dim room at laptop distance and does very little in daylight.
- Without a probe, the room colour is estimated from the background of frames the camera has already white-balanced, assuming the background averages out to grey. Treat that number as approximate.
- The probe assumes the screen's white is neutral. Night Shift and True Tone tint the screen, which shifts its reading.
- The probe assumes the pulse does not reach the background. With a wall close behind you it does: in simulation, 10% of the pulse reaching the wall moved a 2900 K reading by about 170 K.
- The probe has been checked in simulation. It has not yet been checked against a lamp of known colour temperature.
- One brightness target does not suit every skin tone. Set "Target brightness" to what looks right for you.
- The light covers the screen edges. "Reach" sets how far in it goes.
- Only the main display is lit.

## Roadmap

- **v0.3** Train a small model on saved probe data to estimate the room's light colour from a single frame, so the screen does not have to flash. Compare it against the grey-background estimate on lighting it has not seen.
- **v1.0** Signed release.

## Licence

MIT. See [LICENSE](LICENSE).
