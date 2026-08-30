# Bundled font licenses

This addon ships seven font files in `Media/fonts/`. The panel is set in
**Manrope**; Khand and General Sans remain for the windows that have not yet
been rebuilt to the 2026 design.

---

## Khand — SIL Open Font License 1.1

`Khand-Medium.ttf` · `Khand-SemiBold.ttf`

> Copyright 2014-2022 Indian Type Foundry. All rights reserved.
> Khand is a trademark of Indian Type Foundry.

Licensed under the SIL Open Font License, Version 1.1. The full license text is
in [OFL.txt](OFL.txt) alongside the fonts, as the OFL requires — the license must
travel with the font software wherever it is redistributed.

<http://scripts.sil.org/OFL>

---

## General Sans — Indian Type Foundry / Fontshare

`GeneralSans-Regular.ttf` · `GeneralSans-Medium.ttf` · `GeneralSans-Semibold.ttf`

> Copyright 2017-2021 Indian Type Foundry. All rights reserved.
> General is a trademark of the Indian Type Foundry.

License terms as embedded in the font files themselves:

> This Font Software is protected under domestic and international trademark and
> copyright law. You agree to identify the ITF fonts by name and credit the ITF's
> ownership of the trademarks and copyrights in any design or production credits.

Terms: <https://fontshare.com/terms>

This file exists to satisfy that credit requirement: the fonts are identified by
name above, and the Indian Type Foundry's ownership of the trademarks and
copyrights is acknowledged.

---

## Manrope — SIL Open Font License 1.1

`Manrope-Light.ttf` · `Manrope-Regular.ttf`

> Copyright 2018 The Manrope Project Authors
> (https://github.com/sharanda/manrope)

Licensed under the SIL Open Font License, Version 1.1. The full license text is
in [Manrope-OFL.txt](Manrope-OFL.txt) alongside the fonts, as the OFL requires —
the license must travel with the font software wherever it is redistributed.

**These two files are MODIFIED VERSIONS, and that is allowed here.** Manrope is
distributed as a variable font and WoW cannot read one, so each file is a static
instance cut from `Manrope-VariableFont_wght.ttf` at a single weight. The OFL
permits modification and redistribution, and requires a Modified Version to carry
the same license — which it does. It also forbids using a **Reserved Font Name**
in a modified build; Manrope's copyright statement declares none, so the family
legitimately keeps its name.

To regenerate (needs `fonttools`):

```python
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
for style, wght in (("Light", 300), ("Regular", 400)):
    f = TTFont("Manrope-VariableFont_wght.ttf")
    instancer.instantiateVariableFont(f, {"wght": wght}, inplace=True,
                                      updateFontNames=True)
    f.save(f"Manrope-{style}.ttf")
```

Weights are the design's, not a preference: Light carries every label, name and
heading; Regular appears only inside a filled chip.

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

General Sans is in the same position and is still bundled here. It predates the
license change and is retired as the design reaches each remaining window.
