from PIL import Image
im = Image.open("/Users/yinanli/Documents/MusicMiniPlayer/docs/design/2026-09-25-menu-settings/ref-current-menu.png").convert("RGB")
W,H = im.size; px = im.load()
def lum(p): r,g,b=p; return 0.2126*r+0.7152*g+0.0722*b
mx0,mx1,my0,my1=63,469,63,442
print("menu: %.1f x %.1f pt"%((mx1-mx0)/2,(my1-my0)/2))
rowmean=[sum(lum(px[x,y]) for x in range(mx0+30,mx1-30))/(mx1-mx0-60) for y in range(H)]
seps=[y for y in range(my0+6,my1-6) if rowmean[y]>rowmean[y-3]+9 and rowmean[y]>rowmean[y+3]+9]
print("separator lines at pt from top:",[round((y-my0)/2,1) for y in seps], "(px",seps,")")
bands=[];cur=None
for y in range(my0,my1):
    c=sum(1 for x in range(mx0+60,mx1-100) if lum(px[x,y])>200)
    if c>0: cur=[y,y] if cur is None else [cur[0],y]
    else:
        if cur: bands.append(tuple(cur)); cur=None
if cur: bands.append(tuple(cur))
bands=[b for b in bands if b[1]-b[0]>=8]
names=["Show Window","Fullscreen Cover","Lyrics Translation","Translate To","Settings...","Quit"]
print("row | ink top-bottom pt | cap-center pt | text-start pt | icon (w x h pt, left pt, center y pt) | pitch")
prev=None
for b,n in zip(bands,names):
    xs=[x for y in range(b[0],b[1]+1) for x in range(mx0+60,mx1-100) if lum(px[x,y])>200]
    capbottom=b[0]+int((b[1]-b[0])*0.72); center=((b[0]+capbottom)/2-my0)/2
    ipts=[(x,y) for y in range(b[0]-12,b[1]+12) for x in range(mx0+10,mx0+62) if lum(px[x,y])>170]
    ib="-"
    if ipts:
        ix=[p[0] for p in ipts]; iy=[p[1] for p in ipts]
        ib="%.1fx%.1f, left %.1f, cy %.1f"%((max(ix)-min(ix)+1)/2,(max(iy)-min(iy)+1)/2,(min(ix)-mx0)/2,((min(iy)+max(iy))/2-my0)/2)
    pitch="" if prev is None else "%.1f"%(center-prev)
    print("  %-19s| %.1f-%.1f | %.1f | %.1f | %s | %s"%(n,(b[0]-my0)/2,(b[1]-my0)/2,center,(min(xs)-mx0)/2,ib,pitch)); prev=center
pts=[(x,y) for y in range(my0,my1) for x in range(mx0+200,mx1) if px[x,y][2]>200 and px[x,y][0]<120]
ys=sorted(set(p[1] for p in pts)); groups=[]
for y in ys:
    if groups and y-groups[-1][-1]<=2: groups[-1].append(y)
    else: groups.append([y])
for g in groups:
    gx=[p[0] for p in pts if g[0]<=p[1]<=g[-1]]
    print("switch: %.1fx%.1f pt, right inset %.1f pt, cy %.1f pt"%((max(gx)-min(gx)+1)/2,(g[-1]-g[0]+1)/2,(mx1-max(gx))/2,((g[0]+g[-1])/2-my0)/2))
# chevron of submenu
cp=[(x,y) for y in range(my0+190,my1-260+200) for x in range(mx1-40,mx1) if lum(px[x,y])>200]
if cp:
    cx=[p[0] for p in cp]; cy=[p[1] for p in cp]; print("submenu chevron: %.1fx%.1f pt, right inset %.1f"%((max(cx)-min(cx)+1)/2,(max(cy)-min(cy)+1)/2,(mx1-max(cx))/2))
# corner radius: along top-left diagonal find first inside pixel
for d in range(0,30):
    if lum(px[mx0+d,my0+d])<90: print("corner: diagonal enters menu at %dpx -> radius ~%.0f pt"%(d, d/2/0.293)); break
