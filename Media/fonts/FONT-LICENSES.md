# Bundled font licenses

The addon is set entirely in **Saira**. Manrope, Khand and General Sans were
removed in Session 261 when the last window using them was rebuilt — nothing in
the addon referenced them any more, and an unreferenced font is 300 KB of the
zip every installer downloads.

---

## Saira — SIL Open Font License 1.1

`Saira-Light.ttf` · `Saira-Regular.ttf` · `Saira-Medium.ttf` · `Saira-Bold.ttf` · `Saira-Black.ttf`

> Copyright 2020 The Saira Project Authors
> (https://github.com/Omnibus-Type/Saira)

Licensed under the SIL Open Font License, Version 1.1. The full license text is
in [Saira-OFL.txt](Saira-OFL.txt) alongside the fonts, as the OFL requires — the
license must travel with the font software wherever it is redistributed.

**These five files are MODIFIED VERSIONS, and that is allowed here.** Saira is
distributed as a variable font and WoW cannot read one. The OFL permits
modification and redistribution and requires a Modified Version to carry the same
license, which it does. It also forbids a **Reserved Font Name** in a modified
build; Saira's copyright statement declares none — the only occurrence of the
phrase in its OFL is the clause that DEFINES the term — so the family
legitimately keeps its name.

⚠️ **SAIRA HAS TWO AXES AND BOTH MUST BE PINNED.** It varies on `wght` (100–900)
*and* `wdth` (50–125). Instancing weight alone leaves a font that still carries
`fvar` and is therefore still variable — which the game will not read. The
designs are drawn at width 100.

To regenerate (needs `fonttools`):

```python
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
for style, wght in (("Light",300),("Regular",400),("Medium",500),
                    ("Bold",700),("Black",900)):
    f = TTFont("Saira[wdth,wght].ttf")
    instancer.instantiateVariableFont(f, {"wght": wght, "wdth": 100},
                                      inplace=True, updateFontNames=True)
    f.save(f"Saira-{style}.ttf")
```

Weights are the design's, not a preference: Light carries body text, labels and
the bullet separators; Regular the source lines ("From <boss>, <instance>");
Medium the item, raider and boss names; Bold the column headers and the Standings
rail labels; and Black the tags alone — the words that used to be drawn as outlined and filled
chips before Session 261 replaced them with colour-coded text.

Verified after cutting: all five report `usWeightClass` 300/400/500/700/900, none
carries `fvar`, and each covers every accented character in the test fixtures
(Vörnix, Dåmir, Mîrâñ, Brambleÿ, Corvá) plus the marks the panel draws. A missing
glyph in a custom font renders as NOTHING in WoW rather than falling back, so
coverage is checked rather than assumed.

---
## A note on Excon, so it is not tried again

The redesign was drawn in **Excon**, also by the Indian Type Foundry, and it was
rejected on licensing rather than on looks. Fontshare's ITF Free Font License
v2.0 (dated 17 Aug 2026) permits embedding a font in an application and
separately forbids making the font software available through a "repository,
download service, application or platform" in a form that can be "extracted or
used independently" — which is precisely what a `.ttf` sitting loose in an addon
zip on a public repo is. Confusingly, the Excon font files' own embedded terms
carry the older, credit-only text, the same one General Sans ships under; the two
documents disagree and the newer EULA is the one a download is made under.

General Sans was in the same position and is **no longer bundled** — it left with
Manrope and Khand in Session 261, when the last window still setting type in it
was rebuilt. Nothing in the addon is set in an ITF face any more, which is the
tidiest possible answer to the licence question above.
