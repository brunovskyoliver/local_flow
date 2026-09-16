# Approved prototype design handoff

[approved-prototype.html](approved-prototype.html) is the visual authority, reinstated by the user's UI rework request. Translate its app window into SwiftUI. Its browser menu bar, traffic-light drawings, demo footer, sample entries and simulated destinations are not app content. Retain native macOS controls and LocalFlow identity. Earlier Sotto design notes are superseded; retained adapted code keeps its MIT attribution.

| Token | Light | Dark |
|---|---|---|
| Canvas/sidebar/group | #F5F5F3 | #242523 |
| Content surface | #FFFFFF | #1B1C1A |
| Text | #292A28 | #E8E9E4 |
| Muted | #74756F | #A0A29A |
| Line | #EAEAE6 | #333530 |
| Selected | #E9E9E4 | #393B35 |
| Button | #F0F0EC | #34362F |
| Focus/accent | #356B9B | #96BDE0 |

Use system sans-serif throughout. Brand: 20 semibold, tracking -0.7. Heading: 27 semibold, tracking -0.8. Body/navigation: 14. Subtitle: 13. Date, timestamp, secondary settings text and controls: 12.

Window shell: sidebar 208 points; content inset 38 top, 8 trailing/bottom, radius 18 and 1-point border. Inner content has maximum width 940 including padding: 49 top, 55 horizontal, 65 bottom. At window widths below 800, use a 165-point sidebar and 30/23-point top/horizontal content padding. Keep a minimum 720 × 560 window so controls fit.

Sidebar brand begins 77 points below the window top. Navigation has 10-point padding, 10-point icon gap, 6-point corners and 6-point inter-row gap. Only Transcriptions and Settings. Footer reads On this Mac; omit the prototype watermark.

Transcriptions: heading and borderless Search, subtitle Your words, saved on this Mac. Dates are muted 12-point labels. Each date's rows share a 12-point rounded outline; rows have 21-point vertical and 20-point horizontal padding, a 76-point timestamp column and 14-point gap. Full text uses 1.6 line height. Actions reserve space and appear on hover, keyboard or accessibility focus; recovery actions remain visible. Keep quality/recovery badges independent. Paging appears only when required.

Settings: subtitle A few things to make LocalFlow yours. General, Speech model and Permissions headings are 14 medium. Groups use canvas color, 12-point corners and 19-point horizontal inset; rows have 19-point vertical padding and separators. Use compact 6-point rounded controls. Shortcut editing opens a sheet with Cancel/Save. Preserve all shortcut options. Model metadata uses actual values, with verification/details available without adding many permanent rows. Permission buttons show actual status and open the existing permission action.

The recording capsule is opaque #242522 with #F5F5F1 bars, 118 × 38 points. A transparent 35-point trailing area hosts Cancel beside the capsule without covering its bars. Preserve distinct preparing/processing patterns, Escape, accessible cancellation and the existing focus-safe placement. System appearance remains the first-launch default; high contrast may strengthen text and outlines. Native traffic-light geometry, SF Symbol shapes, focus rings and accessibility adaptations are intentional platform differences.

Validate native light/dark renders and resizing, then independently verify routing/focus. No screenshot proves speech accuracy or resource acceptance.

## Compact settings follow-up

The latest user request removes the settings subtitle, explanatory paragraphs, granted permission rows and standing model details. Keep the existing palette and row styling. General shows Shortcut, Appearance and Languages. Speech model has one runtime control when installed. The shortcut button becomes Listening… during inline recording; a single short hint explains release/Escape. No shortcut sheet or preset list remains. These changes supersede the detailed settings mapping above.
