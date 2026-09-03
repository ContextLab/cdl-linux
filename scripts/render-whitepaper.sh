#!/usr/bin/env bash
# Render docs/whitepaper.md to a shareable PDF.
#
# Kept as a script rather than a remembered pandoc invocation, because the whitepaper is
# meant to be re-rendered whenever the design changes and a half-remembered command line
# produces a differently-typeset document each time.
#
# Requires: pandoc, xelatex (mactex-no-gui or equivalent). Fonts are macOS system faces.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

SRC="docs/whitepaper.md"
OUT="docs/pdf/cdl-box-whitepaper.pdf"

command -v pandoc  >/dev/null || { echo "pandoc not installed" >&2; exit 1; }
command -v xelatex >/dev/null || { echo "xelatex not installed (brew install --cask mactex-no-gui)" >&2; exit 1; }
[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

# Charter is a text face designed for legibility at small sizes, which suits a document
# people will read once on a screen. Menlo for code, so identifiers stay unambiguous.
pandoc "$SRC" -o "$OUT" \
    --pdf-engine=xelatex \
    -V mainfont="Charter" \
    -V sansfont="Helvetica Neue" \
    -V monofont="Menlo" \
    -V monofontoptions="Scale=0.85" \
    -V fontsize=11pt \
    -V geometry:margin=1.15in \
    -V linestretch=1.12 \
    -V author="Jeremy Manning" \
    -V colorlinks=true -V linkcolor=NavyBlue -V urlcolor=NavyBlue \
    -V title-meta="cdl-box design note" \
    -H <(cat <<'TEX'
% No single line stranded at the top or bottom of a page. The default penalties allow
% them, and a one-word orphan is the kind of thing a reader notices without knowing why.
\widowpenalty=10000
\clubpenalty=10000
\raggedbottom
% Pull the title block together; pandoc's default leaves a gap where an author would be.
\usepackage{titling}
\setlength{\droptitle}{-2em}
\posttitle{\par\end{center}\vspace{0.4em}}
\predate{\begin{center}\small}
\postdate{\end{center}\vspace{-1em}}
TEX
) || { echo "render failed" >&2; exit 1; }

pages="$(command -v pdfinfo >/dev/null && pdfinfo "$OUT" | awk '/^Pages:/{print $2}')"
printf 'wrote %s (%s, %s pages)\n' "$OUT" "$(du -h "$OUT" | cut -f1)" "${pages:-?}"
