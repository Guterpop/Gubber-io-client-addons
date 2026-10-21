MINESWEEPER POPPER v1.1.2 — by Gubber

FIX: NUMBERS NO LONGER COVER INVENTORY, MAP, OR CHAT
Brodgar draws hafen.ui():overlay() *above* every HUD window.
This version attaches its number painter to the game's MapView widget
instead. Brodgar draws MapView before other HUD widgets, so chat,
inventories, the minimap, and other interface windows cover the numbers.
Numbers are clipped to the MapView bounds. WorldToScreen positions are
converted from root design pixels to the MapView's local pixels.

RETAINED
- Saved tile numbers and database table: cavewarn_tiles
- Automatic restoration after logout/login
- Previous saved-marker grid-boundary fixes (v1.1.1)
- Per-tick projection while moving
- In-game Options > AddOns > Minesweeper Popper settings
- All previously collected observations and confirmed decoder

INSTALL
1. Replace only addons/minesweeper-popper with the folder in this ZIP.
2. Restart Brodgar or run :reload.
3. Revisit previously marked mine tiles; open inventory, map, and chat
   over some visible numbers. The windows should obscure them.

DO NOT delete Brodgar application data or database. This version uses the
existing addon ID and database table, so observations should persist.

NOT TESTED IN THE LIVE CLIENT
The MapView overlay behaviour and its coordinates follow Brodgar's
published addon API, but live verification is still required.
