import sys, pathlib
from playwright.sync_api import sync_playwright
# usage: render.py in.svg out.png size [transparent]
jobs=[l.split() for l in sys.stdin.read().strip().splitlines()]
with sync_playwright() as p:
    b=p.chromium.launch(channel="chrome")
    for src,out,size,*t in jobs:
        s=int(size); pg=b.new_page(viewport={"width":s,"height":int(t[1]) if len(t)>1 else s})
        svg=pathlib.Path(src).read_text()
        pg.set_content(f'<html><body style="margin:0;background:transparent">{svg.replace("<svg ",f"<svg width={s} ",1)}</body></html>')
        pg.screenshot(path=out,omit_background=bool(t) and t[0]=="t",clip={"x":0,"y":0,"width":s,"height":int(t[1]) if len(t)>1 else s})
        pg.close()
    b.close()
