# Remove Main Panel Bottom Shadow

## Problem

The main status panel shows a faint rectangular layer below its rounded glass card. The borderless `NSPanel` is transparent and has its native shadow disabled, so the artifact comes from the SwiftUI `PanelGlassBackground` outer shadow.

The shadow uses an 18-point blur radius with a 10-point downward offset, while the hosting window provides only 14 points of padding. The shadow therefore extends beyond the transparent hosting window and is clipped into a flat rectangular band at the bottom.

## Scope

Remove the outer shadow from the main status panel only. Preserve:

- the glass material and gradient;
- the rounded outline and inner highlight;
- the quota and token cards;
- the action popover's outer shadow;
- all quota, token, color, activity-ring, and refresh behavior.

## Design

Give `PanelGlassBackground` an explicit surface role. The main-panel role does not cast an outer shadow. The actions-popover role keeps the existing shadow. Both roles share the same glass surface drawing so their material, outline, and highlights remain consistent.

This is preferable to deleting the glass background, which would remove the intended panel depth, or merely reducing shadow opacity, which would leave the clipped rectangular artifact visible.

## Verification

Add a focused unit test proving that the main-panel role disables the outer shadow while the actions-popover role retains it. Then run the full Swift test suite, build the application bundle, install it over the stable copy, restart it, and inspect a screenshot of the opened panel for the absence of the bottom band.
