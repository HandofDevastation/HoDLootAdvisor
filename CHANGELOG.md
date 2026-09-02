# Loot Advisor

## v2026.09.02

**Weapons are scored against the hand they would actually occupy**
- An off-hand no longer shows as a huge upgrade for anyone using a two-handed
  weapon. Their off-hand slot is empty, so the drop was being compared against
  nothing and reported as the biggest gain on the list.
- The same fault ran the other way: a one-handed weapon was compared against the
  two-hander it cannot replace on its own.
- Both now read "Needs Pairing" with no gain figure, ranked below everyone who
  gains tonight. How big such an upgrade would be depends on an item nobody can
  see, so no number is invented for it — the condition is named instead, on the
  row and in the tooltip.
- A one-handed weapon is now compared only against the hand it can actually go
  in. For anyone holding a shield or a tome it can only replace the main hand,
  and comparing it against the off-hand was overstating every one-handed drop.
- Dual-wielding is unaffected, including Titan's Grip.

**Scoring matches the website**
- Items are now scored at the level they upgrade to, as the website has always
  done. On Heroic that is ten item levels higher, and it was enough to empty
  whole rankings in game while the same item listed several raiders on the site.
- The item line and the GP cost still show the level that actually drops.

**Eligibility now asks the game**
- The addon reads Blizzard's own per-spec loot filter, so an item your spec
  cannot equip is no longer offered to you just because your class can. A
  Protection Warrior is no longer shown two-handers, and a Beast Mastery Hunter
  is no longer shown one-handed weapons.
- Items nobody has checked are still shown rather than hidden.

## v2026.09.01.1

**When a boss dies**
- Opening on a drop now shows the pieces that just dropped, on the boss that
  dropped them, with the newest one already selected — instead of the season's
  boss list with nothing expanded.
- That list shows everything that dropped, including items your own class
  cannot wear, so the rankings beside them are usable when you are running loot.

**Settings**
- Rebuilt to the design: new order, shorter descriptions, and no more
  descriptions cut off mid-sentence with no way to read the rest.
- Panel Size is now a real scale rather than a percentage, so the value the
  window suggests for sharp text can be typed straight in. It takes an exact
  number as well as the slider. Leave it at 0 to keep whatever your client
  gives you.
- The footer now says when the loot and BIS data was generated, so you can tell
  at a glance whether your copy is current.
- Replaced the game's scrollbar with the design's own.

## v2026.09.01

A visual pass over the whole panel, bringing every screen in line with the design.

**Loot**
- Selecting a boss shows its loot table without auto-selecting an item.
- Item cards are indented under the boss they belong to.
- The upgrade column aligns with the rest of its row.
- Type sizes, weights and colours corrected across the header, the ranking table and the item cards.
- The summary line sits between its dividers and no longer overlaps the boss list.

**Slots**
- Wider rail: slot icon first, then the label.
- A check mark per slot, green once acquired, with two on rings and trinkets.
- Single-line item identity; best-in-slot sources show item icons with their tags inline.
- Separators are centred between entries.

**Windows**
- Removed leftover default-UI borders from the Loot Log and Settings windows.
- The paste box in Import Roster Data no longer shows a scroll bar.
- Settings: restyled input fields, checkboxes and dropdowns, with corrected row spacing.
