# The Saira refresh — what changed, measured against what is built

Working document for the Session 262 restyle. It exists because "be thorough in
cataloguing the differences" is the cheapest thing anyone can do for this job:
every number below was READ OFF THE FIGMA NODE and compared against the constant
that currently produces it, so the build is a list of edits rather than a series
of guesses corrected by screenshots.

**How to read it.** `740 → 800` means the built value is on the left and the
mock's on the right. Anything marked ⚠️ is a decision or a risk, not a
measurement. Anything marked **UNMEASURED** is a screen I have geometry for but
have not yet read for colour and type — say so rather than let a gap look like a
finding (Core §1.1, S258).

Figma page: **HoD Loot Advisor Addon** (`496:81`). Nine frames.

---

## 0. The through-line

Three things drive nearly every individual change:

1. **The window got wider and the rows got shorter.** 740 → 800 wide, and the
   vertical rhythm compresses: boss rows 37 → 29, boss icons 28 → 20.
2. **Chips became text.** Outlined and filled chip bodies are gone entirely;
   what they carried is now colour-coded type. Jason: the outline "takes up too
   much vertical space and was distracting". This is most of the vertical saving.
3. **The badge ramp changed meaning.** It was a heat scale that cools; it is now
   a good/bad scale. See §2 — this is the single most consequential change in
   the refresh and it is NOT a restyle.

---

## 1. Type

**Saira replaces Manrope, and it is the only family.** Excon, General Sans and
Khand all leave. Five static instances are cut in `Media/fonts/`, pinned at
width 100 — Saira varies on `wdth` (50–125) as well as `wght` (100–900), and
instancing weight alone leaves the file still variable, which the game will not
read. Recipe and licence in `Media/fonts/FONT-LICENSES.md`.

| Weight | Where |
|---|---|
| Light 300 | body text, labels, filter captions, the `•` separators |
| Regular 400 | source lines ("From …, The Venomous Abyss") |
| Medium 500 | item names, raider names, boss names, slot names |
| Bold 700 | column headers, Standings rail labels, big figures |
| Black 900 | tags only — MAJOR, O-BIS, TIER PIECE, TARGET … |

⚠️ **Bold is not only for headers.** On Standings it also carries the four rail
block labels, the 34px `#6` and `2` figures, and "Midnight: Season 2".

⚠️ **The mocks disagree with themselves on the tag font** and it cost a round
trip: the Slots page really does use `Inter:Black`, the two Loot frames really do
use `Saira:Bold`. Both readings were correct about different frames. Jason's call
is **Saira Black everywhere**, so Inter is not bundled at all.

**Remnants to ignore, not to reproduce.** Figma's "select all of this font" did
not fully take. Excon survives on the LOOT ADVISOR wordmark, the item-name
blocks, the footer and the Standings rank column; General Sans on the footer and
the Standings raider-name column; Khand on all four Standings rail blocks. None
of these are intent.

---

## 2. Colour — and the one semantic reversal

### The badge ramp is now a good/bad scale

| Badge | Built | Mock |
|---|---|---|
| MAJOR | `#ff595b` red | **`#20ba56` green** |
| MODERATE | `#9f50d4` violet | **`#3382ff` blue** |
| MINOR | `#ac7666` | **`#bb3f22` rust** |
| SIDEGRADE | `#606060` | `#606060` unchanged |

⚠️ **THIS REVERSES A NAMED RULE, DELIBERATELY.** `Style.lua` carries a box
saying MAJOR is red *because* the redesign chose a heat scale over the good/bad
scale the pre-2026 panel used, and that "it inverts what a colour MEANS, so it is
a named token". The refresh goes back to good/bad. Confirmed by Jason; the box
must be rewritten rather than left contradicting the code beneath it.

### BIS and TARGET swap, and green now does two jobs

| Mark | Built | Mock |
|---|---|---|
| BIS (O-BIS / R-BIS / M-BIS) | `#fff468` yellow | **`#9F50D4` violet**, matching the gem icon |
| TARGET / TARGETED | `#20ba56` green | **`#dca75e` gold**, matching the new target icon |
| Tier family (TIER PIECE / TIER TOKEN / CATALYZE TARGET) | — | `#20ba56` green |
| Crafted (Slots) | — | blue `#3382ff` |

⚠️ Session 249 settled that BIS and the target must never share a hue and that
BIS holds the gold-ish one. That still holds — they remain distinct — but the
two have **swapped ends**, so the rule's wording is now wrong and needs amending
rather than quietly contradicting.

⚠️ **Green now means both "MAJOR upgrade" and "tier piece".** They never appear
on the same line today (the Slots page draws no badges; the Loot page draws no
tier classification), so this is a latent collision rather than a live one —
worth knowing before any surface starts showing both.

### Everything else

- Window ground `#0c0721`, unchanged.
- Rules and row separators `#ac7666` at 30%, unchanged.
- The one wash `#ac7666` at 10% — footer band, Standings rail blocks, the Slots
  OBTAINED BY panel, a selected rail row. Unchanged.
- Separator between tags: **`•`, `#606060` ("Trash Grey"), Saira Light.**
  ⚠️ Frame `627:523` uses `|` in violet; that is the outlier, `•` wins.
- `#606060` therefore does double duty as SIDEGRADE and as the separator.
- Selected item card ground `rgba(99,39,83,0.2)`.
- Item icon ring `#9f50d4`, 1px, unchanged from Session 261.

---

## 3. Window and chrome

| | Built | Mock |
|---|---|---|
| Panel | `740 × 600` | **`800 × 600`** |
| Import window | — | `600 × 400` |
| Settings window | — | `600 × 760` in Figma |
| Footer band | 50 tall | 50 tall, now `800` wide |
| Tabs | 27 tall | 27–29 tall (see below) |
| Logo lockup | — | `44 × 28`, wordmark `166 × 28` |

⚠️ **`627:525` is 804 wide**, not 800 — the only frame that is, background and
footer included. Treated as a stray unless told otherwise.

⚠️ **Tab heights are inconsistent across frames**: `74×27` and `80×29` and
`109×29` appear on the same rows in different frames. Building at 29 unless
corrected; the 27s look like the un-updated ones.

⚠️ **The Settings mock is 760 tall against a 600 panel.** Session 258 already
settled this: the canvas is not a constraint, the window is capped and its rows
scroll. Same resolution applies, unchanged.

---

## 4. Loot page

Frames `627:525` (nothing selected) · `627:523` (boss selected) · `627:524`
(boss and item selected).

### Boss list — this is where the vertical compression is

| | Built | Mock |
|---|---|---|
| Row height | `37` | **`29`** (last row `28`) |
| Boss icon | `28` | **`20`** |
| Column width | `200` | **`275`** |
| Icon x | `4` | `4` |
| Row padding | — | left `4`, right `10`, `1` vertical |
| Gap icon→name | — | `10` |
| Boss name | — | Saira Medium `12`, white, `12` leading |

**NEW: per-boss counts.** Each boss row can carry a diamond icon `15×12` with an
`×N`, and a target icon `15×15` with an `×N`, both Saira Light `11` in `#f2bdad`,
`2px` gap icon→number. Genuinely new data — see §9.

- Selected boss row drops its bottom rule and its icon ring turns `#f2bdad`
  (unselected rings are `#9f50d4`).
- Expanded item cards sit indented under their boss at `241` wide, `2px` apart,
  `10/8` padding, ground `rgba(99,39,83,0.2)`.
- Card text is two lines: name Saira Medium `12` at `14` leading, then
  `Back, Cloth • MAJOR • O-BIS • TARGET` at `10`.

### Detail pane

| | Built | Mock |
|---|---|---|
| Item icon | `32` | `32` unchanged |
| Header block | 34 tall, centred on icon | same |
| Facts line | — | one line, `10`, between two `420`-wide rules |
| Ranking columns | RAIDER / UPGRADE / ILVL GAIN / PRIORITY | same |
| Row pitch | — | `20` |

- Rank numbers, raider names class-coloured, `*` suffix marks an ad-hoc raider.
- Verdict badge top-right stays a filled box — **the one surviving chip.**

---

## 5. Slots page

Frames `626:489` (tier-piece state) · `626:518` (ordinary state).

| | Built | Mock |
|---|---|---|
| Rail width | `150` | **`180`** |
| Rail row height | `29` (last `26`) | `29` (last `26`) unchanged |
| Slot icon | `20` | `20` unchanged |
| Slot label | right-aligned at `91` | **left**, Saira Medium `13`, `26` leading, after the icon |
| Pane | `x 230, w 470` | `500` wide |
| OBTAINED BY panel | — | `465` wide, `20` padding, `14` top, `10` gap |

- Slot rows: icon then label, gap `9–11`, right-aligned check marks, bottom rule
  `#ac7666` at 30%. Two check marks on Finger and Trinket (the paired slots);
  dimmed = one of two.
- Selected row ground is the 10% wash.
- Item identity line: icon `32`, name Saira Medium `12`, then tags at `10`.
- Route rows inside OBTAINED BY: icon `32`, name `12`, tags `10`, then the
  source line at `10` — Saira Regular with the boss name in Saira Black.
- Header right: "Destruction Warlock" Saira Bold + "BIS" Saira Light, `14`.
- View dropdown `Overall BIS`, ground `#632753`, `27` tall, `20` padding.

**UNMEASURED:** `626:518`'s colours and type. Geometry only — 14 rail rows at
180×29, a `500×139` detail region with rows of `35/32/32`, and the close `X`.

---

## 6. Standings page

Frame `626:509`.

| | Built | Mock |
|---|---|---|
| Rail block width | `150` | `150` unchanged |
| Rail blocks | 4, heights `86/78/86/86` | 4, same wash, `10` padding |
| Column headers | — | Saira **Bold** `12`, `#9f50d4` |
| Row pitch | `20` | `20` unchanged |
| Rank column | — | `#f2bdad`, `14` |
| EP/GP/PR/Last | — | Saira Light `11`, white, right-aligned |
| Raider names | — | Saira Medium `12`, class-coloured |

- Rail labels Saira Bold `12` `#9f50d4`; big figures Saira Bold `34`.
- "Midnight: Season 2" Saira Bold `14` `#f2bdad`, right-aligned on the tab row.
- Close `X` top-right, `#9f50d4` at 50%.

---

## 7. Runner page — UNMEASURED

Frame `626:510`. Geometry only:

- Rail `180` wide: two `180×29` buttons, a `180×73` status block and a
  `180×93` data block.
- Right column `500` wide: a `500×64` lead paragraph, then two `500×51` blocks
  ("Not Reporting: 14 of 17 …", "Spec Differs from the Roster: 1 …"), separated
  by three full-width hairlines.
- A peer table: names `36×48`, versions `98×48`, gear state `54×48` — three rows
  at `16` pitch, under a `259×16` heading "Who is running the addon:".

Built equivalents exist for all of this (`RN_*` in `Panel.lua`) and the rail
width already matches at 180.

---

## 8. Import and Settings — UNMEASURED

**Import** (`591:2308`, `600×400`): a `520×120` paste box, an
`IMPORT ROSTER DATA` button `192×28`, a `DISCARD LOADED DATA` control, and two
`~458×19` status lines ("Currently Loaded: 16 Raiders • Previous Import …").

**Settings** (`591:2403`, `600×760`): a `522×564` scroll region holding rows of
`520×35`, with `520×51` for the rows whose help text wraps to two lines. Row
heights are MEASURED FROM THE WRAPPED TEXT at build time, never guessed from a
character count — Session 258's rule, unchanged.

---

## 9. Not styling — things that need code

1. **Per-boss counts.** Boss rows show how many best-in-slot and targeted items
   a boss holds. Dungeon tiles gained a BIS count in Session 261
   (`ns.DungeonBisCount`); raid boss rows have no count at all today, and
   *nothing anywhere* counts targeted items per boss. Jason has confirmed he
   wants it.
2. **DOWNGRADE and N/A.** These are new WORDS for states that already exist, not
   new bands. Today a genuine downgrade never gets a badge — scoring returns
   before computing one and the panel prints `NO UPGRADE` in grey; the other
   non-badge states are `NOT FOR YOU` and `UNSCORED`. So this is a relabel, and
   the four thresholds are untouched.
3. **The badge ramp reversal** (§2) is a change to what colour means, and the
   rule box that says otherwise has to be rewritten with it.

---

## 10. What is BUILT, and what is not

**Built and green** (710 smoke · 248 window · 178 comms · 114 roster · parity
276,480 cases · 20 package, under both luajit and lua5.4):

- Saira throughout, five static weights; Manrope, General Sans and Khand deleted.
- The badge ramp reversed to good/bad, with the rule box rewritten rather than
  left contradicting the values beneath it.
- BIS violet, target gold, tier green, crafted blue.
- Chips replaced by colour-coded text everywhere they appeared — item cards, the
  ranking table's UPGRADE column, the Slots identity header, the Slots list rows
  and the OBTAINED BY routes.
- Panel 740 -> 800, with every right-aligned constant moved to the new edge and
  the ranking columns set to their measured positions.
- Boss rows 37 -> 29, icons 28 -> 20, column 200 -> 275, cards 61 -> 45 and
  indented to the boss name.
- Per-boss BIS and target counts, flowing after the boss name.

**NOT done, and honestly:**

- ⚠️ **NOTHING HAS BEEN RENDERED.** Every claim above is a harness result. The
  harness reads values back off widgets, which catches a wrong number and cannot
  catch a wrong-looking screen (Core §1.1, S258: a green harness is not a
  likeness).
- ⚠️ **THE NEW TARGET ICON IS NOT IN THE REPO.** The boss rows draw the existing
  `mark-target.png` because nothing has exported the one Jason added in Figma.
  It will look wrong rather than missing, which is deliberate.
- The four frames listed in §7 and §8 (Runner, Import, Settings, the second
  Slots state) were never read for colour and type. They inherit the global type
  roles and colour tokens, so they will have MOVED with the refresh — but their
  own geometry is untouched and unverified.
- The 804-wide frame and the 27-vs-29 tab heights are still assumed strays.
