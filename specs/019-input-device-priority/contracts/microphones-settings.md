# Contract: Microphones settings and dictation indicator

User-facing behaviour. Strings are final unless the owner changes them in review.

## Settings › Microphones

Placed after General in `SettingsView`.

```text
Microphones
LocalFlow records from the first microphone on this list that is connected.

  ≡  Blue Yeti                         USB            [–]
  ≡  iPhone Microphone                 iPhone         [–]
       Not connected
  ≡  AirPods Pro                       Bluetooth      [–]
       Uses call-quality audio and lowers playback quality while recording.
  ≡  MacBook Pro Microphone            Built-in       [–]
  ≡  System default                    Currently: MacBook Pro Microphone

  [Add microphone ▾]

  To use your iPhone, sign in to the same Apple Account on both devices, turn on
  Continuity Camera on the iPhone, and keep it nearby, locked and in landscape.
  Apple's requirements ›
```

| Element | Rule |
| --- | --- |
| Row order | The stored order. Drag handle reorders (FR-001) |
| Name | Last known name. Two rows with the same name get a short detail: the last 4 characters of the UID, shown as "· 3F2A" |
| Kind label | Built-in, USB, Bluetooth, iPhone, Virtual, Other |
| "Not connected" | Secondary line on unavailable rows; the row is dimmed but can still be moved and removed (FR-004) |
| Bluetooth note | On every Bluetooth row (FR-014) |
| System default row | Shows "Currently: <name>" or "Currently: none". No remove button (FR-002) |
| Remove | Removes immediately. No confirmation; re-adding is one click while the device is connected |
| Add microphone | Menu of connected inputs not in the list. Disabled with "All connected microphones are listed" when empty, and with "The list is full" at 32 |
| Apple's requirements | Opens Apple's Continuity Camera support page in the browser. The only network action, and it is the user's |
| Permission denied | List still shows. The existing permission row in "Permissions needed" stays the place to fix it |

Accessibility: each row reads "<name>, <kind>, <rank> of <count>[, not connected]". Reordering is also available through "Move up" and "Move down" actions on each row, so it does not depend on dragging.

## Indicator

| Moment | Pill | Caption under the pill |
| --- | --- | --- |
| `connecting` | Low bars with a slow pulse | "Connecting to <name>…" |
| `recording` | Today's waveform | "<name>" |
| `recording` after a fallback, first time for this available set | Today's waveform | "Using <name>" for 3 s, then "<name>" |
| No device | Failure style | "No microphone available" with "Microphones…" button |
| Every candidate silent | Failure style | "<name> didn't respond" with "Microphones…" button |

- The caption uses `PillStyle` and the existing notice transitions. It never takes focus and is never a modal alert (FR-012).
- "Microphones…" opens the main window on Settings and scrolls to the Microphones section.
- VoiceOver: the pill's label gains ", <name>" while connecting or recording.

## History

Each dictation's detail shows "Microphone: <name>". Rows from before this feature show "Microphone: Not recorded".

## Meeting transcript

At each microphone segment with `open_reason = device_changed`, the transcript shows a divider "Microphone changed to <name>" at the segment's start offset.
