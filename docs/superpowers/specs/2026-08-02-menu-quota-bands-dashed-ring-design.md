# Menu Quota Bands and Dashed Activity Ring Design

## Goal

Make the menu-bar badge communicate quota urgency more clearly and give the activity indicator a more intentional visual style without changing its size, spacing, accessibility, or active/idle behavior.

## Approved Visual Rules

### Quota colors

Use one shared quota band everywhere the app presents quota color:

- `0...20%`: critical red background, dark red text, red panel tint.
- `21...50%`: warning orange background (`red 1.000`, `green 0.820`, `blue 0.550`, `alpha 0.94`), dark amber text (`red 0.400`, `green 0.200`, `blue 0.000`, `alpha 1`), and orange panel tint.
- `51...100%`: the existing mint-green background, dark green text, green panel tint.
- Unavailable quota keeps the existing neutral translucent background and label color.

The boundary values are inclusive: exactly 20% is red, exactly 50% is orange, and 51% is green.

### Activity ring

Keep the current 12.5-point ring frame, 1.5-point stroke, 285-degree sweep, 75-degree opening, text color, divider spacing, and animation speed. Change the continuous stroke into rounded short dashes using a 1.6-point dash followed by a 2.4-point gap.

The opening makes rotation visually apparent; a complete evenly dashed circle would look almost stationary because of rotational symmetry. While a task is active, the dashed arc continues rotating at 12 frames per second in 30-degree steps. When no task is active, it freezes at its last angle exactly as it does today.

## Architecture

Introduce a small `QuotaColorBand` enum that classifies a remaining percentage as critical, warning, or healthy. `QuotaSnapshot.tint`, `tagBackgroundColor`, and `tagTextColor` all derive from this single band so their thresholds cannot drift apart.

Extract construction of the activity ring's real `NSBezierPath` into an internal helper used by `CompactStatusItemView.draw(_:)`. The helper owns the sweep, stroke width, rounded cap, and dash pattern. It does not change layout or animation state.

## Testing

- Add literal boundary tests for `20`, `21`, `50`, and `51` percent.
- Verify the menu background/text and panel tint are derived from the expected band at the boundaries.
- Verify the actual activity path exposes the required line width, rounded cap, and `[1.6, 2.4]` dash pattern.
- Keep the existing animation, divider, hit-target, tooltip, and accessibility tests unchanged.
- Run the focused UI tests, the complete Swift test suite, a release build, stable-path installation, and a menu-bar screenshot check.
