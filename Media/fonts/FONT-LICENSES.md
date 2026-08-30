# Bundled font licenses

This addon ships five font files in `Media/fonts/`. Both families are by the
**Indian Type Foundry (ITF)**, and neither is modified in any way.

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

## Excon — Indian Type Foundry / Fontshare

`Excon-Light.ttf` · `Excon-Regular.ttf`

> Copyright 2016-2021 Indian Type Foundry. All rights reserved.
> Excon is a trademark of the Indian Type Foundry.

License terms as embedded in the font files themselves:

> This Font Software is protected under domestic and international trademark and
> copyright law. You agree to identify the ITF fonts by name and credit the ITF's
> ownership of the trademarks and copyrights in any design or production credits.

Terms: <https://fontshare.com/terms>

⚠️ **The bundled EULA and the font files disagree, and this is unresolved.**
[ITF-FFL.txt](ITF-FFL.txt) is the ITF Free Font License v2.0, dated 17 Aug 2026,
which shipped in the Excon download. Its §01 permits embedding the font in a
desktop application; its §02 forbids making the font software available through a
"repository, download service, application or platform", and its §03 permits
embedding only where the font "cannot be extracted or used independently". A
`.ttf` in an addon zip on a public repo is extractable. The font files' own
embedded terms — quoted above, and the same ones General Sans ships under — carry
no such restriction.

Jason has asked ITF directly. Until that is answered these two files must not be
pushed to the public repo; see the Session 257 handoff entry.
