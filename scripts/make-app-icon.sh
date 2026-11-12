#!/bin/zsh
# Regenerates Resources/AppIcon.icon (the macOS 26+ app icon, with default,
# dark and tinted appearances) from the SVG masters in DynamicNotchIcons/.
#
# The masters are classic pre-masked icons (a rounded square inset 100px with
# a baked-in shadow and rim). An Icon Composer icon wants full-bleed artwork
# instead, since macOS applies the shape, shadow and edge itself. So each
# master is scaled to fill the canvas, and its outer shadow, mask and rim are
# dropped, before rendering to PNG with Quick Look.
#
# Run this after editing a master SVG; build.sh compiles the result.
set -euo pipefail
cd "${0:A:h}/.."

ICON=Resources/AppIcon.icon
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
mkdir -p $ICON/Assets

python3 - "$WORK" <<'PY'
import re, sys
work = sys.argv[1]
k = 1024 / 824
for name in ["AppIcon", "AppIcon-Dark", "AppIcon-Tinted"]:
    svg = open(f"DynamicNotchIcons/{name}-master.svg").read()
    head, rest = svg.split("</defs>", 1)
    body = rest.rsplit("</svg>", 1)[0]
    body, n = re.subn(r'<g filter="url\(#drop\)">(<rect [^>]*?) rx="185"([^>]*/>)</g>', r"\1\2", body)
    assert n == 1, f"{name}: background rect not found"
    body = body.replace(' clip-path="url(#body)"', "")
    body = re.sub(r'<rect x="10[01]" y="10[01]" width="82[24]" height="82[24]" rx="18[45]" fill="none"[^>]*/>', "", body)
    out = f'{head}</defs><g transform="matrix({k:.6f} 0 0 {k:.6f} {-100 * k:.4f} {-100 * k:.4f})">{body}</g></svg>'
    open(f"{work}/{name}.svg", "w").write(out)
PY

for name in AppIcon AppIcon-Dark AppIcon-Tinted; do
  qlmanage -t -s 1024 -o $WORK $WORK/$name.svg >/dev/null 2>&1
  [[ -f $WORK/$name.svg.png ]] || { echo "error: couldn't render $name" >&2; exit 1; }
  mv $WORK/$name.svg.png $ICON/Assets/$name.png
done

cat > $ICON/icon.json <<'JSON'
{
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "AppIcon.png",
          "image-name-specializations" : [
            { "appearance" : "dark", "value" : "AppIcon-Dark.png" },
            { "appearance" : "tinted", "value" : "AppIcon-Tinted.png" }
          ],
          "name" : "Artwork"
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
JSON
echo "Wrote $ICON"
