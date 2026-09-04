# Even G1 BLE Protocol Reference (Community Reverse Engineering)

> **Nothing in this document is official.** Even Realities has not published a
> G1 SDK or protocol specification. This reference is compiled from community
> reverse-engineering work, packet captures of the official app, and this
> repository's own demo-app implementation. Every entry carries a confidence
> marker — treat `guessed` entries as potentially wrong.
>
> **Confidence legend**
>
> | Marker | Meaning |
> | --- | --- |
> | ✅ `confirmed` | Verified on hardware by multiple independent implementations and/or consistent captures |
> | 👁 `observed` | Seen working in captures or decompiled traffic; some fields not fully understood |
> | ❓ `guessed` | Opcode known, payload layout inferred — may do nothing, or something unexpected |

---

## 1. Transport & Pairing

Each arm of the G1 is a **separate BLE peripheral** running a **Nordic UART
Service**. Connect to **both** arms: neither is a proxy for the other, and many
commands only take effect on one side.

| | |
| --- | --- |
| Service UUID | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` |
| TX (app → glasses, write / write-without-response) | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` |
| RX (glasses → app, notify) | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` |
| Advertised name | `Even G1_<channel>_<L\|R>_<serial>` |
| Serial format | e.g. `S110LAAL103842` → `S110` square frame, `AA` grey (round = `S100`; brown = `BB`, green = `CC`) |
| Default ATT payload | 20 bytes (raise via MTU exchange; ~244 achievable — **required for image transfer**) |
| **Idle timeout** | **~32 s** without any traffic → firmware drops the link (send a heartbeat at least every 28–30 s; this repo sends one every 8 s) |

Channel number: both arms of a pair share the same channel number — this is how
the left peripheral is matched to the right one.

---

## 2. Framing & Responses

### 2.1 Packet shapes

Two packet families share the one TX characteristic. Which one applies is a
**per-opcode property** — it cannot be inferred from the bytes:

```
raw:     [opcode, ...payload]
framed:  [opcode, len_lo, len_hi, seq, ...payload]
         └── len counts its OWN 4 header bytes ──┘
```

The length counting its own header is the single most common source of bugs in
published opcode tables (they mis-read byte 2 as a "sub-command"). Example —
the heartbeat:

```
25 06 00 03 04 03
^^ opcode 0x25
   ^^ ^^ length 6, little endian
         ^^ sequence 3
            ^^ ^^ payload (0x04 tag + counter)
```

> ⚠️ Several community tables read `0x22 0x05` as "command 0x22, sub 0x05".
> It is actually opcode `0x22` with length `5` (SEQ_SYNC).

### 2.2 Status bytes

Generic command responses repeat the opcode, then a status byte:

| Byte | Meaning |
| --- | --- |
| `0xC9` | Success |
| `0xCA` | Failure |
| `0xCB` | Continue (more data) |

### 2.3 Reply quirks (these cost people an afternoon)

1. **Replies are zero-padded** to the ATT payload size. The declared length is
   the only marker of where the useful bytes end. Trim by length, not by
   scanning for zeros.
2. **Framed replies append a result byte *past* the declared length** (a
   "trailer"). Heartbeat reply: `25 06 00 03 04 03 c9` — 7 bytes where the
   length field claims 6; the `0xC9` is real and sits outside the frame.
3. **One reply at a time.** Framed packets echo their sequence byte — the only
   correlation the protocol offers. Keep exactly **one framed command
   outstanding**; two in-flight commands with the same opcode cannot be
   attributed.
4. **`GET_FIRMWARE_INFO` (`0x23 0x74`) has a headerless reply**: bare ASCII,
   zero-padded to 203 bytes, starting with `"net build time: ..."`. It can only
   be matched positionally (safe because sends are serialised).
5. **`BATTERY_REPORT` (`0x2C`) is dual-purpose**: it is both the reply to
   `GET_BATTERY` and an **unsolicited periodic push**. A packet can be both at
   once.
6. **The heartbeat has its own counter**, independent of the global sequence
   counter (`0x25` payload repeats its own counter after a `0x04` tag).

### 2.4 Dual-arm ordering

Commands targeting **both** arms should be sent **left first, wait for the
acknowledgement, then right** — skipping the wait can tear the display (the two
halves update independently as each arm receives its packets).

**Exception:** the BMP bulk transfer (`0x15` chunks) *may* be written to both
arms concurrently — it is a write to arm-local storage, not a display update.

The end marker (`0x20`) and the CRC (`0x16`) are **not** covered by that
exception: the CRC is what makes an arm latch the new frame, so it is a
display update and follows the left-then-right rule. Running the whole
sequence concurrently (`Future.wait([updateBmp("L"), updateBmp("R")])`, what
this repo did until v2.0.1) lets the halves latch at different moments and
shows up as a torn or out-of-sync display. `BmpUpdateManager.updateBmpBothArms`
implements the phased order: concurrent chunks, then `0x20` L→R, then
`0x16` L→R.

---

## 3. Display

| | |
| --- | --- |
| Panel | **576 × 136 px, 1 bit/pixel** (green monochrome micro-LED waveguide) |
| Usable text width | 488 px |
| Default font | 21 px, ~5 lines per screen |
| Bitmap format | Windows BMP, 1 bpp, 72-byte stride, **bottom-up** |
| Bitmap chunk | 194 bytes |
| Storage address | `00 1C 00 00` |
| Refresh budget | A full frame = ~51 chunks/side + end + CRC ≈ **0.6–1.0 s wall time** (iOS, 8 ms inter-chunk delay) → minute precision at most; no per-second animation |

### 3.1 Bitmap transfer — `0x15` / `0x20` / `0x16` ✅

1. Send the BMP in **194-byte chunks** via `BMP_DATA` (`0x15`, raw, both arms):
   - **Packet 0** carries the 4-byte destination address: `[0x15, 0x00, 0x00, 0x1C, 0x00, 0x00, data...]`
   - Later packets: `[0x15, idx, data...]`
2. Send the **end marker** `BMP_END` (`0x20 0x0D 0x0E`), **wait for its
   acknowledgement** (`data[1] == 0xC9`).
3. **Only then** send the CRC `BMP_CRC`: `[0x16, crc32_be...]`,
   `crc = CRC-32/ISO-HDLC` (a.k.a. "Crc32Xz", zlib/PNG/`java.util.zip.CRC32`
   value) **over the storage address bytes followed by the whole image file**,
   transmitted big endian. A CRC over the file *alone* is rejected — the most
   common cause of a silently failing image transfer.

Gotchas:

- **The chunk index is a single byte.** 9856 B / 194 B = 51 chunks, fine.
  But if MTU negotiation fails (20-byte ATT), chunks would need ~704 of them
  and the index wraps — refuse to send instead.
- **The BMP is bottom-up**: the tail of the byte stream is the top of the
  picture. A truncated transfer renders as a blank band across the **top** of
  the panel (a top-down BMP would put the band at the bottom — the diagnostic
  that tells the two apart).
- Header size: this repo's assets use a **64-byte** BMP header
  (64 B + 9792 B pixel data = 9856 B total, 72 B/row, MSB-first); OpenG1
  documents 62 bytes. Both are accepted by the firmware — use the working
  asset template rather than a spec-ideal header.

### 3.2 Text — `SEND_TEXT` `0x4E` ✅

Raw, both arms. Nine-byte header followed by UTF-8 text:

| Offset | Field | Notes |
| --- | --- | --- |
| 0 | opcode `0x4E` | |
| 1 | seq | |
| 2 | total packages | 1–255 |
| 3 | package index | |
| 4 | screen_status | high nibble = mode, low nibble `0x01` = new content |
| 5–6 | new_char_pos | **u16 big endian** (the only BE field apart from the BMP CRC); 0 for plain text; used by Even AI streaming to mark where fresh characters begin |
| 7 | page | |
| 8 | max_page | ≥ 1 |
| 9+ | UTF-8 text | **Split long text on UTF-8 boundaries** — a torn multi-byte sequence reaches the panel as a replacement glyph |

`screen_status` high nibble:

| Value | Meaning |
| --- | --- |
| `0x30` | Even AI displaying |
| `0x40` | Even AI complete |
| `0x50` | Even AI manual |
| `0x60` | Even AI network error |
| `0x70` | Plain text show |

### 3.3 Clear screen — `0x18` 👁

Raw, both arms, no payload. Clears the bitmap layer; also appears to drop the
text layer. (This is what this repo's `Proto.exit()` sends — "back to
dashboard/empty".)

### 3.4 Display power — `0x39` 👁

Framed, both arms. Observed immediately before the panel lights up; payload is
a single enable flag (`0x01` on, `0x00` off). Captures from the official app:
`39 05 00 69 01` / `39 05 00 87 01`; reply echoes with a `0x00` trailer.

### 3.5 Display height/depth — `SET_DISPLAY_SETTINGS` `0x26` (sub `0x08`) ✅

Framed, both arms. Sets the height/depth of the virtual screen (how high and
how far the HUD floats). **Must be sent twice**: first with `preview=1`
(glasses light up and hold), then within a few seconds with `preview=0` to
commit — without the commit the setting is rejected.

> ⚠️ **Source discrepancy.** OpenG1 documents the payload as
> `[sub 0x08, reserved 0x02, preview, height, depth]` (length 9). Captures from
> the official app (G1_Extended docs) show `26 08 00 08 02 01 07 04` — i.e.
> **length 08** with payload `[0x02, preview, height, depth]`. The capture is
> treated as authoritative here.

Ranges: height `0x00–0x08`, depth `0x01–0x09`.
`GET_DISPLAY_SETTINGS` `0x3B` (right arm, ✅) replies `[3B, C9, height, depth]`.

---

## 4. Command Table

Target: `L` = left arm only, `R` = right arm only, `B` = both arms.
"Repo" marks what **this** codebase implements today.

### 4.1 Display

| Opcode | Name | Framing | Target | Payload | Confidence | Repo |
| --- | --- | --- | --- | --- | --- | --- |
| `0x01` | SET_BRIGHTNESS | raw | R | `[brightness 0x00–0x2A (42!), auto 0/1]` | ✅ | — |
| `0x4E` | SEND_TEXT | raw | B | see §3.2 | ✅ | ✔ Text/EvenAI |
| `0x18` | CLEAR_SCREEN | raw | B | – | 👁 | ✔ `Proto.exit()` |
| `0x15` | BMP_DATA | raw | B | see §3.1 | ✅ | ✔ `BmpUpdateManager` |
| `0x20` | BMP_END | raw | B | `0D 0E` | ✅ | ✔ |
| `0x16` | BMP_CRC | raw | B | `[crc32_be]` over address+file | ✅ | ✔ |
| `0x26` | SET_DISPLAY_SETTINGS | framed | B | `[02, preview, height, depth]` (see §3.5) | ✅ | — |
| `0x3B` | GET_DISPLAY_SETTINGS | raw | R | – → `[3B, C9, height, depth]` | ✅ | — |
| `0x29` | GET_BRIGHTNESS | raw | R | – → `[29, 65?, value 0x00–0x2A, auto]` (byte 2 unknown) | ✅ | — |
| `0x39` | DISPLAY_POWER | framed | B | `[enable 0/1]` | 👁 | — |

### 4.2 Session / lifecycle

| Opcode | Name | Framing | Target | Payload | Confidence | Repo |
| --- | --- | --- | --- | --- | --- | --- |
| `0x25` | HEARTBEAT | framed | B | `[04, counter]` — **own counter**, not the global seq; drop after ~32 s idle | ✅ | ✔ every 8 s |
| `0x22` | SEQ_SYNC | framed | R | `[01]` — publishes the app's global sequence counter; sent periodically | 👁 | — |
| `0x4D` | INIT | raw | L | constant `[FB]` — **sent once after connecting** by the official app; "some features misbehave without it", purpose unknown | 👁 | — (candidate for v2) |
| `0x23` | HARD_RESET | raw | B | constant `[72]` — restarts the glasses, no response | ✅ | — |
| `0x23` | GET_FIRMWARE_INFO | raw | B | constant `[74]` → headerless ASCII, 203 B, `"net build time: ..., ver X.Y.Z, JBD DeviceID N"` | ✅ | — |
| `0x37` | GET_UPTIME | raw | B | – → `[37, u32le seconds since boot]` | ✅ | — |
| `0x2C` | GET_BATTERY | raw | B | constant `[01]` → see §6.3 (also arrives unsolicited) | ✅ | — (candidate for v2) |

### 4.3 Getters (identity — replies partially inferred ❓)

| Opcode | Name | Notes |
| --- | --- | --- |
| `0x2C 0x02` | GET_DEVICE_INFO / firmware-software info | ❓ |
| `0x2D` | GET_MAC_ADDRESS | ❓ |
| `0x33` | GET_GLASSES_SERIAL | ❓ |
| `0x34` | GET_DEVICE_SERIAL ("leg SN") | ❓ — **repo: ✔** `Proto.getLegSn()` (used for pairing display) |
| `0x35` | GET_ESB_CHANNEL | ❓ |
| `0x36` | GET_ESB_NOTIFY_COUNT | ❓ |
| `0x3E` | GET_BURIED_POINT | 👁 — local usage telemetry; contents may be personal, never upload |

### 4.4 Audio

| Opcode | Name | Framing | Target | Notes |
| --- | --- | --- | --- | --- |
| `0x0E` | MIC_CONTROL | raw | R | `[enable 0/1]`; once enabled, LC3 frames stream back as `0xF1` events; firmware caps a single capture at ~30 s; ~16 kHz, 10 ms frames (exact encoder config unconfirmed). **Repo: ✔** `Proto.micOn()` |
| `0xF1` | MIC_DATA (event) | – | R | `[seq 0–255, LC3 frame]`; seq wraps at 256 |

### 4.5 Settings

| Opcode | Name | Framing | Target | Payload | Confidence |
| --- | --- | --- | --- | --- | --- |
| `0x03` | SET_SILENT_MODE | raw | B | **enum, not boolean**: `0x0C` = ON, `0x0A` = OFF | ✅ |
| `0x2B` | GET_SILENT_MODE | raw | B | – → `[2B, 69?, 0C/0A, 06/08?]` (bytes 2–3 unknown) | ✅ |
| `0x0B` | SET_HEADUP_ANGLE | raw | R | `[angle 0x00–0x3C (0–60°), 0x01]` — angle at which display turns on when wearer looks up | ✅ |
| `0x32` | GET_HEADUP_ANGLE | raw | R | – → `[32, C9, angle, level]` (capture: `32 6d 0f 01 …` = 15°) | ✅ |
| `0x27` | SET_WEAR_DETECTION | raw | B | `[enable 0/1]` — when on, glasses emit `0xF5 06/07` worn/removed events | ✅ |
| `0x3A` | GET_WEAR_DETECTION | raw | B | – → `[3A, C9, 0/1]` | ✅ |
| `0x2A` | GET_ANTI_SHAKE | raw | B | ❓ |
| `0x08` | SET_BUTTON_CONFIG | framed | B | `[03, action]` — remaps the **head-up** gesture (captures: `08 06 00 00 03 00` = head-up→dashboard, `… 03 02` = head-up→none) | 👁 |
| `0x26` | SET_GESTURE_CONFIG | framed | B | `[05, action]` — remaps **double tap** (captures: `… 05 00` none, `… 05 02` translate, `… 05 03` teleprompter, `… 05 04` dashboard, `… 05 05` transcribe) — shares opcode with display settings, distinguished by subcommand | 👁 |
| `0x10` | CALIBRATION | framed | B | head-tracking calibration state machine: `10 05 00 04 01` = reset 0° reference; `10 07 00 <seq> 02 <a> <b>` = step/result pairs (captures show `02 01 00`, `02 00 00`, `02 01 01`, `02 00 01`) | 👁 |
| `0x3D` | SET_LANGUAGE | framed | B | `[01, language]` (capture: `3d 06 00 14 01 02`) | ❓ |
| `0x3C` | SET_MESSAGE_MODE | framed | B | `[mode]` | ❓ |
| `0x38` | SET_ANCS_CONFIG | framed | L | ANCS bridge config (iOS notification service) | ❓ |
| `0xF4` | SET_DEBUG_MODE | raw | B | `[enable 0/1]` — also the first byte of Android's drifted send path (`0xF4 0x01`) | 👁 |

`action` ids (observed in the official app): `00` dashboard, `02` translate
(*and* used as "none" for head-up — context-dependent, see captures),
`03` teleprompter, `04` navigation, `05` transcribe.

### 4.6 Dashboard (firmware-rendered)

The G1 firmware has a **built-in dashboard** (time + weather, rendered by the
firmware itself — the app only pushes the data). Opened/closed by gesture
(default double tap), events `0xF5 1E/1F`.

| Opcode | Name | Framing | Target | Notes |
| --- | --- | --- | --- | --- |
| `0x06` | SET_DASHBOARD | framed | B | multiplexed by first payload byte; reply **echoes the sequence** |
| `0x50` | DASHBOARD_LOCK | framed | R | `[01, locked 0/1]` (capture: `50 06 00 00 01 01`) |
| `0x1E` | SET_QUICK_NOTE | framed | B | capture: `1e 10 00 29 03 01 00 01 00 03 00 01 00 01 00 00` (16 B) |
| `0x58` | SET_CALENDAR_EVENT | framed | L | ❓ |

**`0x06` subcommand `0x01` — time & weather:**

```
[06, len, 00, seq, 01,
 epoch32_le(4B), epoch64_le(8B),
 weather_icon(1B), temp_C(1B), celsius_flag(0/1), 24h_flag(0/1)]
```

**`0x06` subcommand `0x06` — layout:**

```
[06, len, 00, seq, 06, mode(0), panel(0)]
mode:  00 = full, 01 = dual, 02 = minimal
panel (FULL/DUAL only): 00 notes, 01 stock, 02 news, 03 calendar, 04 navigation, 05+ empty
```

**Weather icons:** `00` none, `01` night, `02` clouds, `03` drizzle, `04`
heavy drizzle, `05` rain, `06` heavy rain, `07` thunder, `08` thunderstorm,
`09` snow, `0A` mist, `0B` fog, `0C` sand, `0D` squalls, `0E` tornado, `0F`
freezing, `10` sunny.

> **Relevance for us:** a firmware dashboard means the clock widget needs only
> ~17 bytes/minute of traffic instead of a full 9.8 KB BMP frame. Candidate for
> a later "face 0" (needs a weather source for the weather slot).

### 4.7 Notifications

| Opcode | Name | Framing | Target | Payload | Confidence | Repo |
| --- | --- | --- | --- | --- | --- | --- |
| `0x04` | SET_NOTIFICATION_CONFIG | raw | L | chunked JSON allow-list: `[04, chunk_count, chunk_index, ≤180 B JSON...]`; JSON: `{"calendar_enable":bool,"Call_enable":bool,"Msg_enable":bool,"Ios_mail_enable":bool,"app":{"List":[{"id":"com.app","name":"App Name"}],"enable":true}}` | ✅ | ✔ manual test page |
| `0x4B` | SEND_NOTIFICATION | raw | L | chunked JSON: `[4B, count, index, ≤180 B...]`; `NotifyModel{msg_id, app_identifier, title, subtitle, message, time_s, display_name}` — **must match an allow-listed app** | ✅ | ✔ manual test page |
| `0x4C` | CLEAR_NOTIFICATION | raw | L | – | 👁 | — |
| `0x2E` | GET_WHITELIST | raw | L | – | ❓ | — |

### 4.8 Features

| Opcode | Name | Framing | Target | Notes |
| --- | --- | --- | --- | --- |
| `0x09` | SET_TELEPROMPTER | framed | B | ❓ payload layout not established (the demo app drives teleprompter through the `0x4E` text path) |
| `0x0A` | SET_NAVIGATION | framed | B | ❓ opcode accepted, payload is a guess; community fallback = formatted text, which works |
| Firmware update | — | — | — | **deliberately unimplemented by the community**: getting it wrong bricks discontinued hardware (firmware v1.5.6 zip is publicly hosted by Even) |

---

## 5. Events (glasses → app, unsolicited)

### 5.1 `STATE_CHANGE` `0xF5` ✅

`[F5, subcode, data...]` — touchbar, wear, case, dashboard. Touchpad meanings
are **user-remappable** since FW v1.4.x (see §4.5), so always read the mapping
before assuming.

| Subcode | Meaning |
| --- | --- |
| `0x00` | Touchpad **double tap** (this repo: wired to "exit"/clear) |
| `0x01` | Touchpad **single tap** (this repo: Even AI page prev/next; **face-navigation candidate for v2**) |
| `0x02` / `0x03` | Head up / head down |
| `0x04` / `0x05` | Triple tap (two variants) |
| `0x06` / `0x07` | **Glasses worn / removed** (only if wear detection `0x27` is on) |
| `0x08` / `0x0B` | Case lid open / closed |
| `0x09` | Charging state (`00`/`01`) |
| `0x0E` | Case charging (`00`/`01`) |
| `0x0F` | Case battery percent (`00–0x64`) |
| `0x11` | BLE paired success |
| `0x17` / `0x18` | **Touchpad hold start / hold end** (this repo: `0x17` on **left** = Even AI trigger; hold on the right is a plain hold) |
| `0x1E` / `0x1F` | Dashboard opened / closed |
| `0x20` | Translate/transcribe toggled |
| `0x0A`, `0x12` | Unassigned/unknown — surfaced, not dropped |

### 5.2 `MIC_DATA` `0xF1` ✅

`[seq 0–255, LC3 audio...]` — see §4.4.

### 5.3 `BATTERY_REPORT` `0x2C` ✅

```
[2C, 66, percent(0x00–0x64 = 0–100), ...voltage/charge-state bytes...]
```

- Byte 1 is the `0x66` tag, byte 2 is the **percent (0–100)**; the remaining
  bytes carry voltage and charge state and **vary between firmware builds**.
- Arrives both as a reply to `GET_BATTERY` **and** as a periodic unsolicited
  push — per arm, so **battery level for each side is available** (the
  official app shows both).
- A packet can be both at once: resolve the pending request *and* dispatch the
  event.

---

## 6. Known Quirks & Pitfalls (checklist)

1. Idle timeout ≈ **32 s** — heartbeat every ≤ 28 s (repo: 8 s ✅).
2. Framed length **includes** the 4 header bytes; byte 2 is *not* a subcommand.
3. Trim replies by **declared length** (zero-padded); framed replies carry a
   real **trailer byte** past the length.
4. One framed command **outstanding** at a time.
5. Heartbeat counter is **separate** from the global sequence.
6. `new_char_pos` in `0x4E` is **big endian** (only BE field apart from the
   BMP CRC).
7. BMP CRC is over **storage address + file**, not the file alone.
8. BMP is **bottom-up**; truncation shows as a blank band at the *top*.
9. BMP chunk index is **1 byte** — needs the negotiated MTU (~194 B chunks).
10. Both-arm commands: **left first, wait, then right** (except `0x15` bulk
    chunks, which may run concurrently).
11. `0x26` display settings must be sent **twice** (preview=1, then preview=0
    within seconds) or the setting is rejected.
12. `0x03` silent mode is an **enum** (`0C` on / `0A` off), not a boolean.
13. Brightness range is **0–42**, not 0–100.
14. Mic capture is capped at **~30 s** per session.
15. Send `0x4D FB` (INIT) to the left arm once after connecting — the official
    app always does; some features misbehave without it.
16. Text must be split on **UTF-8 boundaries** across packages.
17. Touchpad/gesture meanings are **user-remappable** (FW ≥ 1.4.x).

---

## 7. Known Unknowns (don't waste a weekend here)

- `SET_NAVIGATION` (`0x0A`) and `SET_TELEPROMPTER` (`0x09`) payload layouts.
- Field layouts of `GET_DEVICE_INFO` (`0x2C 02`), MAC (`0x2D`), serials
  (`0x33`–`0x36`), ESB (`0x35`/`0x36`), buried point (`0x3E`).
- Unknown filler bytes in some getter replies (`0x29 → 65`, `0x2B → 69`,
  `0x32 → 6d`).
- `SET_QUICK_NOTE` (`0x1E`) payload semantics.
- Exact LC3 encoder configuration (frame size consistent with 16 kHz / 10 ms).
- Whether 576×136 is a sub-region of a larger 640×200 sensor — untested
  (all working transfers use 576×136, so that is the practical canvas).
- `SET_DEBUG_MODE` (`0xF4`) semantics.
- Firmware update flow (intentionally not reverse-engineered; bricking risk).

---

## 8. Sources

| Source | Type | Used for |
| --- | --- | --- |
| [gabrielevierti/openg1-sdk](https://github.com/gabrielevierti/openg1-sdk) (`docs/PROTOCOL.md`, `protocol/openg1.protocol.yaml`) | Python SDK + simulator, 49 commands with confidence markers, firmware 1.4.5/1.5.6 | primary command/event tables, framing, status bytes |
| [LabbeSimon/G1_Extended](https://github.com/LabbeSimon/G1_Extended) (`Even Realities G1 BLE Protocol.txt`) | Open-source Android client + protocol notes with **real captures** of the official app | dashboard payloads, gesture/button config captures, battery report, display on/off, calibration, reconnect strategy (2 s × 30 s then ramp to 5 min) |
| [even-realities/EvenDemoApp](https://github.com/even-realities/EvenDemoApp) (this repo's ancestor) | Official demo | heartbeat, BMP pipeline, text pipeline, notification pipeline, `0xF5` wiring |
| [FJiangArthur/Helix-iOS](https://github.com/FJiangArthur/Helix-iOS) | Native Swift G1 companion (iOS 17+/Xcode 27) | iOS-side BLE patterns, HUD bitmap rendering with widget layouts |
| [emingenc/even_glasses](https://github.com/emingenc/even_glasses), [emingenc/g1_flutter_blue_plus](https://github.com/emingenc/g1_flutter_blue_plus) | Python + Flutter wrappers | cross-checks |
| [galfaroth/awesome-even-realities-g1](https://github.com/galfaroth/awesome-even-realities-g1) | Index | project discovery |
| r/EvenRealities "G1 protocol/implementation demystified" thread (2026-05) | discussion | protocol-doc provenance |
| [aiglass-compare.com G1 entry](https://www.aiglass-compare.com/device/even-realities-g1) | hardware spec sheet | display/SoC specs (640×200 panel, nRF5340, 20 Hz, no Wi-Fi/speaker) |

**Firmware:** v1.5.6 zip:
`https://cdn.evenreal.co/firmware/3adb8ebbd35c2343409d6d0c9fe6cbb9.zip`

---

## 9. What This Repo Implements vs. What's Next

| Feature | Status in EvenG1 |
| --- | --- |
| Scan / connect (both arms, `Pair_<channel>`) | ✅ `ble_manager.dart`, `ios/Runner/BluetoothManager.swift` |
| Heartbeat 8 s | ✅ |
| BMP push (576×136, 194 B chunks, CRC) | ✅ `bmp_update_manager.dart` |
| Text push + paging (Even AI stream) | ✅ `text_service.dart`, `evenai.dart` |
| Mic on + LC3 stream (Even AI) | ✅ |
| Notification whitelist + notify (manual test) | ✅ `views/features/notification/` |
| `0xF5` handling: exit / page / AI start / hold end | ✅ |
| **`0x4D` INIT after connect** | ⏳ v2 (cheap, "some features misbehave without it") |
| **`0x2C` battery per side → face** | ⏳ v2 (face: link/battery widget) |
| **`0x27` wear detection → pause updates** | ⏳ v2 (battery saver for the face loop) |
| Brightness `0x01`, silent mode `0x03`, head-up `0x0B` | ⏳ v2 (settings) |
| Firmware dashboard `0x06` (time+weather) | ⏳ v2 (low-traffic clock face) |
| Custom face engine (BMP rendering in Dart) | 🚧 **v2 — this project** |
| Android: notification relay, ANCS, background keep-alive | ⏳ later (Android foreground service) |
