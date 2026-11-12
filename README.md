# OpenMap: Zephras Isle

A small companion addon for [OpenMap](https://github.com/openmap-world/openmap) on WoW Forever (1.60.1).

OpenMap's stitched world has no place for Zephras Isle (its own continent, map 2991), so OpenMap opens
Blizzard's flat map of it. This addon lays the game's own minimap tiles on that map and adds zoom levels,
mixed in by OpenMap's own Minimap detail settings (read only). It also draws the isle's five caves the way
OpenMap's `Close.lua` draws caves that only have minimap pictures.

- `Data.lua`: the isle's minimap tile file IDs (WDT 7198644, MAID chunk, build 1.60.1.70790) and the caves'
  WMO minimap pictures, read the way OpenMap's `tools/map-caves/wmo.py` reads them.
- `Media/Mask.tga`: a land mask over tiles 25..34 x 22..30, so the sea around the isle stays Blizzard's.
- `Core.lua`: the overlay, zoom levels, caves, and the reopen-view handling.

Commands: `/zephras` opens the map; `/zephras 50 34.6` centres there zoomed in; `/zephras toggle` and
`/zephras caves` switch the minimap and the caves (also in OpenMap's menu).

Shared for OpenMap ([issue #17](https://github.com/openmap-world/openmap/issues/17)); take whatever helps.
Written with AI assistance (Claude). MIT licensed.
