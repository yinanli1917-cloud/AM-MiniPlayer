from PIL import Image
im=Image.open("/Users/yinanli/Documents/MusicMiniPlayer/docs/design/2026-09-25-menu-settings/ref-system-settings-trackpad.webp").convert("RGB")
px=im.load(); wx0,wy0=152,152
def lum(p): return 0.2126*p[0]+0.7152*p[1]+0.0722*p[2]
def trans(x,lo,hi,thr=4):
    out=[];prev=None
    for y in range(lo,hi):
        p=px[x,y]
        if prev is not None and abs(lum(p)-lum(prev))>thr: out.append((y,prev,p))
        prev=p
    return out
print("x=1200 (blank area) transitions y 640..1100:")
for t in trans(1200,640,1100): print("   y=%d %s->%s  = %.1f pt from window top"%(t[0],t[1],t[2],(t[0]-wy0)/2))
print("x=1200 transitions y 240..560 (preview cards + segmented):")
for t in trans(1200,240,560,6): print("   y=%d %s->%s  = %.1f pt"%(t[0],t[1],t[2],(t[0]-wy0)/2))
# card corner radius: card top-left at (638,657)
def iscard(p): return 240<=p[0]<=249 and abs(p[0]-p[2])<3
cx0,cy0=638,657
for d in range(0,40):
    if iscard(px[cx0+d,cy0+d]): print("card corner radius ~ %.1f pt (diag %dpx)"%(d/2/0.293,d)); break
# separator inset: separator line y ~ 762 (from earlier) - find its x extent
for sy in (762,868,974):
    xs=[x for x in range(600,1600) if 225<=px[x,sy][0]<=240 and abs(px[x,sy][0]-px[x,sy][2])<4]
    if xs: print("separator y=%d: x %d-%d -> inset left %.1f pt from card left, right %.1f pt"%(sy,min(xs),max(xs),(min(xs)-638)/2,(1557-max(xs))/2))
# toggle at x=1480
ty=[y for y in range(660,730) if px[1480,y][2]>200 and px[1480,y][0]<60]
print("toggle track at x=1480: y %d-%d -> %.1f pt tall, center %.1f pt from card top"%(min(ty),max(ty),(max(ty)-min(ty)+1)/2,((min(ty)+max(ty))/2-657)/2))
kn=[(x,y) for y in range(660,730) for x in range(1440,1560) if min(px[x,y])>240 and px[x,y-1][2]>150]
kx=[p[0] for p in kn]; ky=[p[1] for p in kn]
print("knob approx: x %d-%d y %d-%d -> %.1fx%.1f pt"%(min(kx),max(kx),min(ky),max(ky),(max(kx)-min(kx)+1)/2,(max(ky)-min(ky)+1)/2))
# first row text baseline positions
def bands(x0,x1,y0,y1,thr):
    out=[];cur=None
    for y in range(y0,y1):
        c=sum(1 for x in range(x0,x1) if lum(px[x,y])<thr)
        if c>0: cur=[y,y] if cur is None else [cur[0],y]
        else:
            if cur: out.append(tuple(cur)); cur=None
    if cur: out.append(tuple(cur))
    return out
print("row1 title/desc bands (pt from card top):",[((b[0]-657)/2,(b[1]-657)/2) for b in bands(655,1000,660,760,200)])
print("row pitch check: toggle centers", [((min([y for y in range(lo,hi) if px[1480,y][2]>200 and px[1480,y][0]<60])+max([y for y in range(lo,hi) if px[1480,y][2]>200 and px[1480,y][0]<60]))/2-657)/2 for lo,hi in ((660,730),(770,840),(880,950),(985,1060))])
# 'Point & Click' segment text; 'Set Up Bluetooth' button height
by=[y for y in range(1100,1190) if 236<=px[1300,y][0]<=246 and abs(px[1300,y][0]-px[1300,y][2])<4]
print("button 'Set Up…': y %d-%d -> %.1f pt tall"%(min(by),max(by),(max(by)-min(by)+1)/2))
