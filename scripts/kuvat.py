"""Valikoitujen työmaakuvien käsittely sivustolle.

Lukee listan tiedostosta data/kuvat.json (tunniste -> alkuperäinen kuva + alt-teksti),
tekee alkuperäisistä (assets/valokuvat/) kaksi WebP-kokoa hakemistoon assets/kuvat/
ja kirjoittaa mitat build-skriptiä varten tiedostoon data/kuvat.manifest.json.

Uusi kuva sivulle: kopioi alkuperäinen assets/valokuvat/-hakemistoon, lisää rivi
data/kuvat.json-tiedostoon, aja `python scripts/kuvat.py` ja lisää tunniste
components.jsx:n SERVICES- tai CASES-listaan.
"""
import json
from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "assets" / "valokuvat"
OUT_DIR = ROOT / "assets" / "kuvat"
SM_WIDTH = 640    # ruudukot ja pikkukuvat
LG_EDGE = 1440    # kuvagalleria, pidempi sivu


def save_webp(im, path, quality):
    im.save(path, "WEBP", quality=quality, method=6)
    return list(im.size)


def main():
    entries = json.loads((ROOT / "data" / "kuvat.json").read_text(encoding="utf-8"))
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest = {}

    for slug, entry in entries.items():
        src = SRC_DIR / entry["src"]
        sm_path = OUT_DIR / f"{slug}-sm.webp"
        lg_path = OUT_DIR / f"{slug}-lg.webp"
        fresh = sm_path.exists() and lg_path.exists() and (
            not src.exists() or src.stat().st_mtime <= min(sm_path.stat().st_mtime, lg_path.stat().st_mtime)
        )

        if fresh:
            # Alkuperäinen puuttuu tai ei ole muuttunut: luetaan mitat valmiista tiedostoista.
            sm_size = list(Image.open(sm_path).size)
            lg_size = list(Image.open(lg_path).size)
        else:
            if not src.exists():
                raise SystemExit(f"Alkuperäinen kuva puuttuu: {src}")
            with Image.open(src) as im:
                im = ImageOps.exif_transpose(im).convert("RGB")
                lg = im.copy()
                lg.thumbnail((LG_EDGE, LG_EDGE), Image.LANCZOS)
                lg_size = save_webp(lg, lg_path, 80)
                sm = im.resize((SM_WIDTH, round(im.height * SM_WIDTH / im.width)), Image.LANCZOS)
                sm_size = save_webp(sm, sm_path, 76)
            print(f"  {slug}: {lg_size[0]}x{lg_size[1]}")

        manifest[slug] = {"alt": entry["alt"], "sm": sm_size, "lg": lg_size}

    out = ROOT / "data" / "kuvat.manifest.json"
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{len(manifest)} kuvaa -> {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
