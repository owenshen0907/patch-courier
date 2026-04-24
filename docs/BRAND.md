# Patch Courier Brand Notes

## Visual direction

Patch Courier uses a practical engineering-product identity:

- Concept: trusted email carries a patch request back to the local machine, where Codex can do the work under local policy.
- Primary motif: envelope + patch lines + courier route.
- Palette: deep navy, warm amber, mint/teal, and paper cream.
- Tone: precise, local-first, reliable, not cartoonish.

## Assets

- README hero: `docs/assets/patch-courier-hero.svg`
- Primary icon preview: `docs/assets/patch-courier-icon.png`
- App icon set: `Targets/Mac/Assets.xcassets/AppIcon.appiconset/`

## Regenerating app icons

The app icons are generated locally from a deterministic Pillow script:

```bash
python3 scripts/generate_brand_assets.py
```

The script does not call any external image model or API. It rewrites all PNGs listed in `Targets/Mac/Assets.xcassets/AppIcon.appiconset/Contents.json` and updates `docs/assets/patch-courier-icon.png`.

## Asset brief

- Asset type: app icon and README banner.
- Product: Patch Courier.
- Text in icon: none.
- Text in banner: project name plus short positioning line.
- Style: local-first developer tool, trusted delivery, patch workflow, macOS-ready.
- Avoid: generic chat bubbles, cloud-first imagery, mascot-heavy illustration, tiny unreadable code text.
