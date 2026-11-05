#!/usr/bin/env bash
# export_pdfs.sh
# Prints the four rendered notebooks (homecredit-eda/*.html) to PDF with headless
# Google Chrome. Nothing is re-run: each PDF is printed from the existing HTML, so
# it shows exactly the results recorded there. This matters most for
# modeling.html, because re-running modeling.qmd under newer package versions
# changes its results.
#
# A temporary copy of each HTML file gets print-only CSS (wrapped code, readable
# tables, no printed link URLs); the HTML files themselves are not changed.
# 02_personas prints in landscape so its 24-column candidate tables fit.
#
# Run from the repository root:  bash reports/export_pdfs.sh

set -euo pipefail

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
SRC="homecredit-eda"
OUT="reports"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PRINT_CSS='<style>
@page { size: Letter; margin: 0.55in 0.5in; }
@media print {
  html, body { font-size: 10.5pt !important; }
  pre, pre code, div.sourceCode, pre.sourceCode { white-space: pre-wrap !important; word-break: break-word !important; overflow: visible !important; max-height: none !important; }
  a[href]:after, abbr[title]:after { content: none !important; }
  img, figure, svg { max-width: 100% !important; height: auto !important; break-inside: avoid; }
  tr, thead { break-inside: avoid; }
  table { width: 100% !important; max-width: 100% !important; font-size: 8.5pt !important; }
  th { white-space: normal !important; overflow-wrap: anywhere; padding: 2px 3px !important; vertical-align: bottom !important; }
  td { white-space: normal !important; padding: 2px 3px !important; }
  .table-responsive, .cell-output-display { overflow: visible !important; }
  h1, h2, h3, h4 { break-after: avoid; }
}
</style>'
LANDSCAPE_CSS='<style>@page { size: Letter landscape; margin: 0.4in; } @media print { table { font-size: 6.5pt !important; } }</style>'

for name in eda modeling 01_business_impact 02_personas; do
  extra="$PRINT_CSS"
  [ "$name" = "02_personas" ] && extra="$extra$LANDSCAPE_CSS"
  # Insert the CSS just before </head> in a temporary copy.
  EXTRA="$extra" python3 -c '
import os, sys
html = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(html.replace("</head>", os.environ["EXTRA"] + "</head>", 1))
' "$SRC/$name.html" "$TMP/$name.html"
  "$CHROME" --headless=new --disable-gpu --no-pdf-header-footer \
    --run-all-compositor-stages-before-draw --virtual-time-budget=20000 \
    --user-data-dir="$TMP/profile" --print-to-pdf="$OUT/$name.pdf" \
    "file://$TMP/$name.html" 2>/dev/null
  echo "Wrote $OUT/$name.pdf"
done
