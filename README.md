# trmnl-radio-weather-plugin

## Radio Weather

![Radio Weather on the TRMNL X](assets/screenshot.png)

The weather as a calm early-80s hi-fi receiver, for [TRMNL](https://trmnl.com) e-paper displays:

- **Dials** (TRMNL X): a barometer with the pressure trend, and a temperature dial with today's low and high.
- **Console**: the temperature in segment digits with what to wear (clothing, umbrella, sunglasses); block meters for wind and gusts, UV, air quality, humidity, pollen and pressure when they matter, grey cells for what is still to come today.
- **Rain or sun**: an hour calendar when rain is coming; otherwise sunrise, sunset and the moon as it looks from your location.
- **Bottom strip**: the coming days or hours.
- **Indoor sensor**: with a TRMNL temperature sensor on the screen, indoor becomes the big reading and outdoor moves beside it, or show another TRMNL's sensor (a hallway upstairs) with outside as the big reading. Readings older than 3 hours are ignored.

Every view (full, half horizontal, half vertical, quadrant), 1-bit, greyscale and colour screens, dark mode, 24 or 12 hour time. When Open-Meteo is slow or down, the last saved forecast shows with its time.

### Settings

| Setting | What it does |
|---|---|
| Location | City, postal code or latitude,longitude |
| Temperature unit | Celsius or Fahrenheit |
| Time format | 24 hours (17:00) or 12 hours (5:00 PM) |
| Bottom strip | Days, hours, or hours with days after 18:00 |
| Hide title bar | Hides the title bar on the full view |
| Indoor readings | With a TRMNL temperature sensor on this screen: the indoor reading becomes the big number, outdoor moves beside it. The screen's own sensor is found automatically. |
| CO2 meter | Shows the CO2 meter of a TRMNL CO2 sensor |
| Sensor from another TRMNL | Optional device number (the digits in the address of its page on trmnl.com). Empty: this screen's own sensor. |
| Sensor label | Optional short name, for example Upstairs, shown beside the house icon and in the readout. Empty: the icon alone. |
| Main reading | Which reading is the big black one: Automatic (the sensor when it is this screen's own, outside when it comes from another TRMNL), Sensor, or Outside. The other one is second and grey, its meters after. |

Data comes from [Open-Meteo](https://open-meteo.com); no key is needed.

## Development

Built with [trmnlp](https://github.com/usetrmnl/trmnlp).

```bash
cd plugin
trmnlp serve        # preview
trmnlp test         # RSpec specs in plugin/tests
node ../test/model/run.js   # pure-logic tests of the weather model
(cd .. && npm install && node tools/build.js)   # after editing source/shared.liquid
ruby ../tools/sync_trmnl_i18n.rb   # re-sync TRMNL's translations
```

## Editing

Edit `source/shared.liquid` (all comments live there), then run `node tools/build.js`: it writes `plugin/src/shared.liquid` (Liquid comments stripped, long Liquid variable names shortened, page script minified), which is what trmnlp pushes. Never edit the built file; the model tests fail when it is out of date or over 84 KB.

Two render-check tiers, same spec (`tools/render_check_spec.rb`), run base first, then devices, then ship:

| Tier | Cases | Run |
|---|---|---|
| Base | `tools/render_check_cases.json` (OG, X, colour OG; scope unchanged) | `cd plugin && SW_CASES="$(cat ../tools/render_check_cases.json)" SW_OUT=<dir> trmnlp test ../tools/render_check_spec.rb` |
| Devices | `tools/render_check_devices.json`: every TRMNL model x full/hh/hv/quadrant, portrait full+hv, one dark, full and portrait full with an indoor sensor | `tools/check_devices.sh [out_dir] [model-substring]` prints a pass/fail table per device (about 35 min for all, one browser) |

Regenerate the device file after TRMNL adds a model: `python3 tools/make_device_cases.py` (reads trmnl.com/api/models). Playdate is left out until the owner decides on small screens.

## Open items

| Item | Detail |
|---|---|
| DIALR at 17.4 | The temperature dial radius shrinks (0.2119 against 0.2348) when the main reading is 17.4 C: the 20 tick label then sits at the right edge. Already so at 202a477 with an own sensor, so not from B13. DIALR-SPREAD stays red for `b13-x-rem-sensor` and `b13-x-long-label` until the dial is fixed. Known red, not to be waved through. |
| Device tier, own-sensor cases | 8 of the 117 `-sens` cases are red at 202a477 and unchanged by B13: `avalue_epd_42s__full-sens`, `avalue_epd_42s__full-port-sens`, `generic_16_9__full-sens` (icon level with block row), `kobo_clara_2e__full-sens` (digit height), `kobo_libra_color__full-port-sens`, `onyx_boox_go_10_3_lumi__full-port-sens`, `tcl_nxtpaper_14__full-port-sens` (row 2 icon meets low), `palma__full-port-sens` (empty band under the days). |

## Licence

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 ExcuseMi.

The weather texts (the `sw_i18n` capture in each `plugin/src/<view>.liquid`, the slots between the `I18N_TRMNL` markers in `shared.liquid`) come from
[usetrmnl/trmnl-i18n](https://github.com/usetrmnl/trmnl-i18n) and stay under its MIT licence; see
[third_party/trmnl-i18n-LICENSE](third_party/trmnl-i18n-LICENSE). The weather icons are loaded from trmnl.com and are not part of this repository.
