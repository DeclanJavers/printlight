# Printlight design brief

Design the complete interface for **Printlight**, an iPhone camera app. The app is fully built and
working; this brief covers what it does and what the design must support. Your designs will be
implemented in SwiftUI by an engineer, so be precise and complete.

## What the app is

Printlight is a still camera for people who care how their photos look. It shoots RAW, discards
Apple's automatic processing (the flat, bright, over-sharpened "phone look"), and develops every
photo through a simulation of real motion-picture and stills film: a camera negative printed onto
print film or paper, built from measured Kodak and Fujifilm data. The goal is pictures that look
like frames from a film, straight out of the camera.

It's inspired by cinematographer Steve Yedlin's camera app, made for director Rian Johnson. Users
are photographers and film people. They know what exposure, white balance, halation and film stocks
are, and they want a camera that feels like a precise instrument, not a filter app.

The core promise: point, shoot, and get a beautiful film-like photo. Deep controls are available but
never in the way.

**Scope:** taking and editing RAW photos on iPhone. Photos live in the user's photo library, not
inside the app. Each shot is one photo in Photos: the RAW original, with Printlight's developed look
attached as a non-destructive edit (with all its settings). Photos shows the developed image, Photos'
own "Revert" returns to the plain RAW, and Printlight can reopen any of its shots and change the look
at any time. The app itself stores almost nothing.

## Platform and constraints

- iPhone only, iOS 17 or later, portrait-locked UI. Primary device: iPhone 17 Pro (402 × 874 pt,
  Dynamic Island). Must also work on smaller iPhones (6.1") without clipping or overlap.
- Photos can be taken in any orientation (the device's orientation is recorded), even though the
  UI itself doesn't rotate. You may design icons or labels that counter-rotate in landscape.
- Used outdoors in sunlight and indoors in the dark. The viewfinder image is the hero; chrome must
  never compete with it or tint how colours are judged.
- Implementable in SwiftUI with system frameworks. Use SF Symbols, or supply custom icons as SVG.
  Any font must be either a system font or one we can legally bundle (name the license).
- Accessibility: 44 × 44 pt minimum touch targets, VoiceOver labels for every control, adequate
  contrast in bright sun, and state not conveyed by colour alone. Note how layouts respond to larger
  Dynamic Type sizes where text appears.

## Screens and features

### 1. Camera (main screen)

The app opens straight to this. Everything here must be operable one-handed.

**Viewfinder**
- Live camera image in a 3:4 frame (the shape of the photos), with the selected film look applied
  live.
- Important: the live look is a close approximation, not an exact match of the final photo. iOS
  can't provide unprocessed preview frames while shooting RAW, and the true result is visible right
  after capture. The design shouldn't promise exactness.
- Tap anywhere in the frame to focus and meter at that point. It needs a focus/exposure indicator
  that appears at the tap point and fades.
- Brief visual feedback at the moment of capture.
- Optional highlight-clipping warning (zebra stripes): diagonal stripes drawn over areas that are
  blown out. The user can toggle it on and off, and the setting is remembered. It's a guide, not an
  exact sensor reading.
- Toggle between the film look and Apple's ordinary preview, to compare. Labelled states: "Look"
  vs "Apple".

**Exposure compensation (before capture)**
- −3 to +3 stops in 1/3-stop steps, default 0. Changes the camera's real exposure for the next shot.
- Needs to be quick to adjust with the thumb, show the current value, and have a fast reset to 0.
  Haptic tick per step is expected.
- Must be clearly distinct from the "Exposure" development setting (see Look settings), which
  brightens or darkens the photo afterwards. Users must not confuse the two.

**Lens selection**
- Buttons for each back camera the phone has, labelled by zoom: typically "0.5", "1", and a telephoto
  such as "4" (varies by phone; some have only one lens). Active lens clearly marked.

**Shutter**
- Large, unmistakable. Disabled while a capture is in progress, while the camera isn't running, or
  when the camera can't shoot RAW.

**Last-shot thumbnail**
- Shows the most recent photo (from this session, or the newest in the library at launch); tapping
  opens the Library.
- On capture it shows a quick preview immediately, then updates to the finished photo a few seconds
  later. It needs a "developing" state (the full photo takes about 3–6 seconds to process and save).
- Empty state when there are no Printlight photos at all.

**RAW format indicator**
- Shows what the current lens captures: "ProRAW 48MP", "RAW 12MP", or "No RAW". "No RAW" is a
  warning state: the shutter is disabled.

**Access to Look settings**
- A control that opens the Look settings panel over the camera. The viewfinder must stay partly
  visible and keep updating while the panel is open, so changes can be judged live.

**Messages**
- Short transient notices (for example "Saved to Photos", or an error such as "Couldn't save:
  …"). Must not block shooting.

**Camera states to design**
- Starting (brief)
- Running
- Camera access denied: explanation plus a button to open Settings
- Camera failed: short reason text, e.g. "No back camera found."
- No RAW available on the current lens

### 2. Look settings (shared by the Camera sheet and the Editor)

One panel of development settings. The same controls appear over the camera, where they set the
default for future shots, and in the Editor, where they apply to one photo. Changes apply
immediately to the image behind the panel.

**Film** (choose one; the most important choice, so give it prominence)

| Name | Description |
|---|---|
| Vision3 250D | Cinema negative · 2383 print (default) |
| Vision3 500T | Fast cinema negative · 2383 print |
| Vision3 50D | Fine-grain daylight cinema · 2383 print |
| Portra 400 | Stills negative · Endura paper |
| Ektar 100 | Vivid stills negative · Endura paper |
| Gold 200 | Consumer negative · Supra Endura paper |
| Fuji Pro 400H | Stills negative · Crystal Archive paper |
| Mono | Panchromatic black and white · 2383 tone |

More films may be added later, so the selector must scale to 10–15 entries. Small sample swatches
or thumbnails per film would help (we can render them from the user's current photo if you design
for that).

**Tone**

| Setting | Range | Default | Notes |
|---|---|---|---|
| Exposure | −3 to +3 stops | 0 | Brightens/darkens the photo after capture |
| Black lift | 0 to 0.04 | 0.01 | How deep the blacks go |

**Colour**

| Setting | Range | Default | Notes |
|---|---|---|---|
| Warmth | −1 to +1 | 0 | Cooler ↔ warmer |
| Tint | −1 to +1 | 0 | Green ↔ magenta |

**Texture**

| Setting | Range | Default | Notes |
|---|---|---|---|
| Clarity | 0 to 1 | 0.25 | Fine detail and crispness |
| Halation | 0 to 0.5 | 0.12 | Red glow around bright lights, like film |
| Halation threshold | −1 to +3 stops | +1 | How bright something must be to glow |
| Grain | 0 to 0.04 | 0.012 | Film grain amount |

**Custom LUT (optional)**
- Import a `.cube` colour-grading file from the Files app. It's applied on top of the film.
- Show the imported LUT's name, with actions to replace it and remove it.
- Strength 0 to 1 (default 1), shown only when a LUT is loaded.
- Import can fail with a message, which needs an inline error state. Possible messages:
  - "Only 3D LUTs are supported."
  - "LUT size 80 isn't supported (2–64)."
  - "Only LUTs with a 0–1 input domain are supported."
  - "Couldn't read that file."
- Needs a one-line hint that these should be standard Rec.709 "look" LUTs, not camera-log LUTs.

**Panel-wide**
- Summary of state: at default ("Standard") vs. how many settings are changed.
- Reset everything to defaults.
- Reset a single setting to its default quickly. Each setting needs a visible marker for its
  default value, and an easy way to land exactly on it.
- Values shown numerically, with the formats above.
- Required credit line, always present somewhere in the panel: "Film data: spektrafilm profiles by
  Andrea Volpato, CC BY-SA 4.0."

### 3. Library

Every RAW photo in the user's library that Printlight can see, newest first. That means Printlight's
own shots plus any other RAW (ProRAW from Apple's Camera app, other camera apps, earlier imports).
Opened from the camera's thumbnail. The images come from the user's photo library and show each
photo as it currently looks in Photos.

- A grid of shots. It should feel like a contact sheet, and work smoothly with hundreds of shots.
- Tap a shot to open it in the Editor. Opening needs a short "opening" state, plus a **download
  progress** state (0–100%) when the original only lives in iCloud (common with "Optimize iPhone
  Storage"). That can take several seconds on slow connections.
- A shot that's still being processed after capture appears first, with a "developing" state. It can
  already be opened.
- Select mode for deleting several shots. Photos then shows its own system confirmation, which the
  design can't restyle.
- Shot count. Optional: date grouping, and a filter or badge to tell Printlight-developed photos
  apart from untouched RAWs from other apps.
- With **Limited** access, only Printlight's own shots and photos the user chose are visible. The
  screen needs a quiet notice and an "Add photos" action that opens the system picker for choosing
  more.
- A RAW from another app opens with the user's current default look; saving attaches Printlight's
  look to it (Photos can still revert).
- Shots deleted in the Photos app disappear here automatically.
- **States to design:**
  - Loading
  - Empty: "No RAW photos yet"
  - No access: the user didn't allow photo access. Shots still save to Photos, but can't be listed
    here. Needs an explanation and an "Open Settings" button. Limited access is enough.
  - Download in progress
  - A shot that can't be opened (deleted, or has no RAW)

### 4. Editor (re-develop a shot)

Opened from the Library. Works on any RAW in the Library. A Printlight shot starts from the settings
it was saved with; any other RAW starts from the user's default look.

- Large view of the photo, re-developed live as settings change (each update takes about 0.15 s).
- A loading state while the photo is prepared (about 1–2 seconds after opening).
- The full Look settings panel. The user should be able to hide it to see the whole image, and
  bring it back.
- **Save:** develops the photo at full resolution and updates that same photo in Photos with the
  new look (no duplicate is created; the RAW original is untouched and Photos can always revert).
  It takes a few seconds and needs a progress state, then a success or failure message.
- Unsaved-changes handling (not built yet; design it): leaving with changes should ask, or make
  clear the edit isn't saved.
- **Use as default:** makes these settings the default for future shots. It needs a confirmed state
  when the editor's settings already equal the default.
- **Done:** returns to the camera.

### 5. System touchpoints

- First-run permission prompts:
  - **Camera** access.
  - **Photos** access, asked at the first save. iOS offers **Full**, **Limited** and **Don't Allow**.
    Limited is enough for Printlight's own shots; other RAWs then appear only once the user adds
    them. If the user refuses, saving still works but the Library is unavailable.
- Design any pre-prompt or explanation screens you think are needed (for example, explaining why
  Limited is fine), plus the denied states.
- Every capture is saved automatically to Photos as one photo (RAW + Printlight edit), and also
  appears in a Printlight album there.

## What I need back

1. **Screens:** Camera, Look settings (over the camera, and in the Editor), Library and Editor.
   Include every state listed above (camera states, developing, empty thumbnail, library
   empty/no-access/downloading, LUT loaded/empty/error, saving, messages).
2. **Design tokens:** colours (hex, with usage), type scale (font, size, weight, tracking), spacing,
   corner radii, stroke widths, shadows/materials.
3. **Components with all states:** default, pressed, disabled, active/selected, and any
   loading/error states. Cover every control type: sliders, film selector, toggles, lens buttons,
   shutter, thumbnail, exposure compensation, buttons, messages.
4. **Motion:** durations and easing for panel presentation, capture feedback, thumbnail updates,
   focus indicator and value changes.
5. **Haptics:** which interactions get which feedback.
6. **Layout specs** for iPhone 17 Pro and a 6.1" iPhone, with safe areas and the Dynamic Island.
7. **Accessibility notes:** VoiceOver labels and order, plus Dynamic Type behaviour.

Keep to the feature set above. If you have ideas for new features (shooting modes, more controls,
sharing), put them in a clearly separate "proposals" section rather than mixing them into the core
screens.
