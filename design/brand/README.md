# HeyVedu brand assets

Generated separately from the user-supplied black and mint ribbon reference using the built-in ImageGen tool, October 2, 2026. The source PNGs preserve generated transparency. These are raster reproductions of the reference.

## Individual deliverables

- `../../assets/brand/heyvedu-wordmark.png`: tightly framed transparent ribbon V and HeyVedu text, used in the website header and footer.
- `../../assets/brand/heyvedu-mark.png`: standalone transparent ribbon V.
- `../../assets/brand/heyvedu-app-icon.png`: black rounded tile and mint ribbon, on a transparent 1024px canvas with macOS padding.
- `../../assets/brand/heyvedu-app-icon.icns`: compiled macOS icon.
- `../../assets/brand/favicon.ico`, `favicon-{16,32,192,512}.png`, and `apple-touch-icon.png`: browser and touch sizes.
- `../../HeyVedu/Assets.xcassets/AppIcon.appiconset`: all ten macOS icon sizes, selected in Debug and Release builds.
- `../../HeyVedu/Assets.xcassets/BrandMark.imageset`: menu-bar mark. SwiftUI renders its silhouette as a template in the ready, idle state; status indicators continue to represent recording, processing, loading, and errors.

`website-preview.png` records the website rendering. Xcode's asset compiler successfully produced `AppIcon.icns` and `Assets.car`. The full desktop app was not rebuilt for this asset change.

## Repackage

Run `python3 scripts/prepare-brand-assets.py` from the repository with Pillow installed. It trims canvas padding without changing artwork colors or alpha, then creates the website exports and Xcode catalog. To refresh the standalone ICNS, compile the catalog with Xcode's `actool` and copy its `AppIcon.icns` output into `assets/brand/heyvedu-app-icon.icns`.

## Generation prompt set

Each call supplied the same attached brand board as its exact edit target and requested a transparent background.

### Wordmark

Use case: background-extraction. Input image: exact edit target, HeyVedu brand board. Produce ONE individual production-ready horizontal website logo asset: isolate the bottom-right lockup, black and mint ribbon V followed by exact black bold text 'HeyVedu'. Preserve precisely the original ribbon curves, split, mint green color and black bold typography. Remove the entire cream backdrop and ALL other artwork. Real transparent background, tight horizontal composition with small even padding, crisp clean edges. No new elements, no mockup, no shadows, no board. This is extraction of the supplied logo, not a redesign.

### App icon

Use case: background-extraction. Input image: exact edit target, HeyVedu brand board. Produce ONE individual square app-icon asset by isolating the TOP RIGHT black rounded-square tile with mint green ribbon V. Preserve EXACTLY its shape and logo: rounded black tile, mint left descending ribbon curving around base, mint right diagonal blade with black fold slit. Remove cream background and everything outside this icon. Transparent outside tile only, black tile remains opaque, no text, no shadows. Square canvas, icon centered with small even padding appropriate for macOS app icon. Crisp production artwork, do not redesign or add elements.

### Standalone mark

Use case: background-extraction. Input image: exact edit target, HeyVedu brand board. Produce ONE individual logo-mark asset: isolate ONLY the large LEFT black and mint ribbon V, preserving exactly the original black curved descending left stroke with rounded base and the mint right diagonal blade with the cream negative gap/fold changed to transparency. Remove the cream background and all other artwork, text and app tile. Real transparent backdrop, crisp edges, tight square framing and modest even padding. Exact faithful extraction, no redesign, no shadows, no text.
