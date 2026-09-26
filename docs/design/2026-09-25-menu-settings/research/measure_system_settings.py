from PIL import Image
im=Image.open("/Users/yinanli/Documents/MusicMiniPlayer/docs/design/2026-09-25-menu-settings/ref-system-settings-trackpad.webp").convert("RGB")
W,H=im.size; px=im.load()
def lum(p): r,g,b=p; return 0.2126*r+0.7152*g+0.0722*b
wx0,wy0=152,152
def transitions(line, axis, lo, hi, thr=5):
    out=[]; prev=None
    for i in range(lo,hi):
        p = px[i,line] if axis=='x' else px[line,i]
        if prev is not None and (abs(p[0]-prev[0])+abs(p[1]-prev[1])+abs(p[2]-prev[2]))>thr:
            out.append((i,prev,p))
        prev=p
    return out
print("y=1200 transitions (x px, before, after):")
for t in transitions(1200,'x',560,700): print("  ",t, "-> %.1f pt from window left"%((t[0]-wx0)/2))
print("y=700 transitions near card left:")
for t in transitions(700,'x',590,700): print("  ",t, "-> %.1f pt"%((t[0]-wx0)/2))
print("y=700 transitions near card right:")
for t in transitions(700,'x',1540,1600): print("  ",t, "-> %.1f pt from window left; %.1f from window right"%((t[0]-wx0)/2,(1597-t[0])/2))
print("x=700 transitions (card top/bottom, separators) between y 640..1100:")
for t in transitions(700,'y',640,1100): print("  ",t, "-> %.1f pt from window top"%((t[0]-wy0)/2))
# selected row (Trackpad) around y 1284
blue=lambda p: p[2]>200 and p[0]<60 and p[1]<140
xs=[x for x in range(160,600) if blue(px[x,1284])]; ys=[y for y in range(1230,1330) if blue(px[380,y])]
print("selected row: x %d-%d y %d-%d -> %.1fx%.1f pt; left %.1f pt from window; right gap to sidebar edge?"%(min(xs),max(xs),min(ys),max(ys),(max(xs)-min(xs)+1)/2,(max(ys)-min(ys)+1)/2,(min(xs)-wx0)/2))
for d in range(0,40):
    if blue(px[min(xs)+d,min(ys)+d]): print("  selected row corner radius ~ %.1f pt"%(d/2/0.293)); break
# Notifications tile (red) at y ~375
red=lambda p: p[0]>200 and p[1]<110 and p[2]<110
xs=[x for x in range(160,320) if red(px[x,375])]; ys=[y for y in range(340,410) if red(px[220,y])]
print("tile: x %d-%d y %d-%d -> %.1fx%.1f pt; left %.1f pt from window; center y %.1f"%(min(xs),max(xs),min(ys),max(ys),(max(xs)-min(xs)+1)/2,(max(ys)-min(ys)+1)/2,(min(xs)-wx0)/2,((min(ys)+max(ys))/2-wy0)/2))
for d in range(0,30):
    if red(px[min(xs)+d,min(ys)+d]): print("  tile corner radius ~ %.1f pt"%(d/2/0.293)); break
# label x start for Notifications
lx=[x for x in range(240,420) for y in range(360,390) if lum(px[x,y])<110]
print("sidebar label starts x=%d -> %.1f pt from window; gap from tile right %.1f pt"%(min(lx),(min(lx)-wx0)/2,(min(lx)-max(xs))/2))
def capheight(x0,x1,y0,y1,thr=120):
    ys=[y for y in range(y0,y1) for x in range(x0,x1) if lum(px[x,y])<thr]
    return (min(ys),max(ys),(max(ys)-min(ys)+1))
print("'N' of Notifications cap px:",capheight(252,275,355,395), "-> font ~ %.1f pt (cap/0.705/2)"%(capheight(252,275,355,395)[2]/0.705/2))
print("'T' of Trackpad cap px:",capheight(786,808,172,212), "-> font ~ %.1f pt"%(capheight(786,808,172,212)[2]/0.705/2))
print("'N' of Natural cap px:",capheight(658,680,675,715), "-> font ~ %.1f pt"%(capheight(658,680,675,715)[2]/0.705/2))
print("'C' of Content cap px:",capheight(658,676,712,745,190), "-> font ~ %.1f pt"%(capheight(658,676,712,745,190)[2]/0.705/2))
print("'8' of 87% cap px:",capheight(822,840,208,235,150), "-> font ~ %.1f pt"%(capheight(822,840,208,235,150)[2]/0.705/2))
print("'P' of Point cap px:",capheight(714,732,580,615), "-> font ~ %.1f pt"%(capheight(714,732,580,615)[2]/0.705/2))
print("'S' of Search cap px:",capheight(245,262,288,318,150), "-> font ~ %.1f pt"%(capheight(245,262,288,318,150)[2]/0.705/2))
# search field geometry
sf=[x for x in range(160,600) if 220<=px[x,302][0]<=240 and abs(px[x,302][0]-px[x,302][2])<6]
sfy=[y for y in range(260,345) if 220<=px[380,y][0]<=240 and abs(px[380,y][0]-px[380,y][2])<6]
print("search field: x %d-%d y %d-%d -> %.1fx%.1f pt, top %.1f pt"%(min(sf),max(sf),min(sfy),max(sfy),(max(sf)-min(sf)+1)/2,(max(sfy)-min(sfy)+1)/2,(min(sfy)-wy0)/2))
# first row top (Notifications tile) vs search bottom
print("gap search bottom -> first tile top: %.1f pt"%((355-max(sfy))/2))
# sidebar group gaps: tile centers list via red/other detection at x=220 saturation
def sat(p): return max(p)-min(p)
cent=[]; y=340
while y<1400:
    if sat(px[220,y])>70 or lum(px[220,y])<100:
        y0=y
        while y<1400 and (sat(px[220,y])>70 or lum(px[220,y])<100): y+=1
        if y-y0>25: cent.append(((y0+y-1)/2-wy0)/2)
    y+=1
print("tile centers pt:",[round(c,1) for c in cent]); print("pitches:",[round(cent[i+1]-cent[i],1) for i in range(len(cent)-1)])
# toggle detail: measure knob
tx=[x for x in range(1440,1560) if blue(px[x,693])]
print("toggle track x %d-%d (%.1f pt); knob: white run inside?"%(min(tx),max(tx),(max(tx)-min(tx)+1)/2))
wk=[x for x in range(min(tx),max(tx)+1) if min(px[x,693])>235]
print("  knob x %d-%d -> %.1f pt wide"%(min(wk),max(wk),(max(wk)-min(wk)+1)/2))
ty=[y for y in range(670,720) if blue(px[1470,y])]
print("  track y %d-%d -> %.1f pt tall; center %.1f pt from card top (card top at y=%d)"%(min(ty),max(ty),(max(ty)-min(ty)+1)/2,((min(ty)+max(ty))/2-657)/2,657))
# preview tiles / segmented positions
print("segmented: track x extent at y=596:")
seg=[x for x in range(600,1600) if (px[x,596][0]>=225 and abs(px[x,596][0]-px[x,596][2])<6 and px[x,596][0]<245) or blue(px[x,596])]
print("  x %d-%d -> %.1f pt wide, left %.1f pt from window"%(min(seg),max(seg),(max(seg)-min(seg)+1)/2,(min(seg)-wx0)/2))
