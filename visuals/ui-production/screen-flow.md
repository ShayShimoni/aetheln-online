# Opening Screen Flow

```text
Boot
  -> Studio / legal splash
  -> Connection check
  -> Main Menu
       -> Continue -> Character Selection -> Enter World
       -> Play -> Character Selection
       -> Settings
            -> Display
            -> Audio
            -> Controls
            -> Accessibility
       -> Accessibility
       -> Credits
       -> Quit confirmation
```

## Global Requirements

- `Back` returns to the immediate prior layer and never silently discards
  modified settings.
- Unsaved settings open an Apply / Discard / Cancel confirmation.
- A blocking network failure opens a modal with Retry and Back.
- Mouse, keyboard, and gamepad share one visible focus owner.
- Input prompts update when the active input device changes.
- Character deletion requires an explicit confirmation and is not the default
  focused action.
- `Enter World` is unavailable while character data is incomplete or a session
  request is already pending.
- Before the faction stage, character identity shows `FACTION UNASSIGNED` and
  no Doctrine information.

## Main Menu Focus Order

1. Continue
2. Play
3. Settings
4. Accessibility
5. Credits
6. Quit

If no resumable character exists, Continue is disabled and initial focus moves
to Play.

