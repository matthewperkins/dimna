# oEZ icon credits

The oEZ icon (`oez-icon.svg` and the `oez-*.png` renders) shows **Kalila and Dimna**, the two
jackals whose conversations frame the first books of the *Panchatantra*, known in its Arabic
and later European versions as *Kalila wa-Dimna* or the *Tales of Bidpai*. Two jackal heads in
profile overlap like stacked silhouettes: Dimna, the schemer, in slate blue behind; Kalila, the
cautious one, in vermilion in front; on a parchment tile with a gold border and a small leaf
and fruit sprig.

It is an **original drawing**, written by hand as SVG paths and shapes. No image was traced,
embedded or vectorised. It takes general inspiration, in mood only, from:

- the illustrated Arabic manuscripts of *Kalila wa-Dimna* (13th–14th century), which paint
  Dimna blue and Kalila red on parchment with gold and dark green foliage and thin dark
  outlines;
- the cover of Ramsay Wood's retelling, *Kalila and Dimna: Selected Fables of Bidpai*, for the
  flat warm colours and the long-muzzled, tall-eared jackal profile. Nothing from that
  illustration (by Margaret Kilrenny, in copyright) is copied.

The icon was drawn by Claude Opus 5.5, an AI model made by Anthropic, at the request of the
project's owner.

`candidates/` keeps the three designs that were considered (`a-stacked.svg` is the one in
use; `b-facing.svg` has the two facing each other with crossing muzzles; `c-roundel.svg` is a
manuscript-style medallion with both looking up at a blossom), and `contact-sheet.png` shows
each at 32, 48, 64, 128 and 256 px on a dark and a light background.

To re-render the PNGs: `rsvg-convert -w N -h N oez-icon.svg -o oez-N.png` for N in
32, 48, 64, 128, 256.
