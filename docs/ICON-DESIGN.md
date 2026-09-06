# icon design

the OpenBottle icon is drawn by hand as SVG. it uses no generated image as a
source.

## idea

the three shapes do one job each:

- the bottle names the app;
- the offset orange cap makes the bottle visibly open;
- the Play mark says this is where a Windows game starts.

the old image tried to communicate glass with bubbles, liquid ribbons, bloom,
reflections, and neon lighting. those details looked synthetic at full size and
turned into blue noise in Finder. the replacement uses a centered silhouette,
one background plane, and six colors.

## palette

| use | color |
| --- | --- |
| upper background | `#263746` |
| lower background | `#111b24` |
| bottle outline | `#12343b` |
| bottle | `#61c7b2` |
| bottle shade | `#3b958a` |
| label | `#f3eee2` |
| cap | `#f0a158` |

## small sizes

`images/openbottle-icon-small.svg` is an optical drawing for the 16 and 32 px
assets. it removes the large icon's shadow and glass highlight, thickens the
outline, and enlarges the label and Play mark. this keeps the idea readable
instead of asking a downsampler to decide which details matter.

the 64–1024 px assets use `images/openbottle-icon.svg`.

## rebuilding

on macOS:

```sh
./scripts/render-app-icon.py
./scripts/render-app-icon.py --check
```

the script uses the system `sips` renderer, writes every app-catalog and
thumbnail size, checks its dimensions and alpha channel, and can verify that
the committed PNGs still match the SVGs.

the layout follows Apple's advice to keep one recognizable idea centered, use a
simple background, and remove details that fail at smaller sizes:
[App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons).
