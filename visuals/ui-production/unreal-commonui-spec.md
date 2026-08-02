# Unreal CommonUI Specification

## Root Layers

Use one persistent root layout with separate stacks:

```text
W_RootLayout
  GameLayer
  MenuLayer
  ModalLayer
  NotificationLayer
  LoadingLayer
```

Only activatable screens that must own or block input belong on an activatable
stack. Small labels, tooltips, static panels, and decorative controls should
remain regular or common user widgets.

## Suggested Widgets

- `W_MainMenu`
- `W_Settings`
- `W_Accessibility`
- `W_CharacterSelection`
- `W_ConfirmDialog`
- `W_ConnectionError`
- `W_LoadingGuard`
- `W_PrimaryButton`
- `W_SecondaryButton`
- `W_TabButton`
- `W_SettingRow`
- `W_InputPrompt`
- `W_RosterCard`

## Style Assets

Create centralized CommonUI style assets for:

- Display and UI text
- Primary, secondary, destructive, and disabled buttons
- Tab buttons
- Input-action prompts
- Selection cards
- Modal panels
- Loading indicator

Do not duplicate brush, font, or padding values inside individual screens.

## Nine-Slice Guidance

The rectangular panel and button SVGs use a 24 px source inset. After raster
export, configure UMG Box draw mode and normalized margins from the verified
texture dimensions. Keep corner cuts and focus diamonds outside stretchable
center regions.

## Focus and Input

- Default focus is set when each activatable screen becomes active.
- Focus restoration returns to the control that opened a child layer.
- Primary focus uses a brighter border, corner diamonds, and increased
  luminance in addition to Ember color.
- Hover never steals focus from active gamepad navigation.
- Every action is reachable without a pointer.
- Provide universal Accept and Back actions and platform-specific prompt data.

## Background Treatment

The background plate fills the viewport using Aspect Fill. Add a separate,
code-controlled scrim rather than baking UI contrast into every background.
Allow the left/right scrim strength to vary by screen while preserving
background artwork.

## Scaling

Author layouts against 1920x1080, use anchors and scale boxes, and test:

- 1280x720
- 1920x1080
- 2560x1440
- 3440x1440
- 3840x2160

Respect platform safe zones. Avoid positioning essential controls solely by
absolute coordinates.

## Accessibility

- Expose text scale, subtitle treatment, high-contrast focus, reduced motion,
  camera comfort, and color-vision presets.
- Do not encode hostility, faction, focus, or validation status by hue alone.
- Decorative star cracks, Ember flicker, and loading rotation must honor
  reduced motion.
- Use actual text widgets rather than rasterized labels.

