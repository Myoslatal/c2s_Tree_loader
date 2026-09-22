import sys
try:
    from PIL import Image
    import numpy as np
except Exception as e:
    print("NOPIL", e); sys.exit(0)
p = "/mis/SteamLibrary/steamapps/compatdata/977400/pfx/drive_c/users/steamuser/AppData/LocalLow/Computer Lunch/Cell to Singularity/cepack_shot2.png"
im = Image.open(p).convert("RGB")
a = np.asarray(im).astype(np.int16)
h, w, _ = a.shape
# node interiors are mid-grey (~110-150) on a near-black background
lum = a.mean(axis=2)
sat = a.max(axis=2) - a.min(axis=2)
mask = (lum > 70) & (lum < 190) & (sat < 40)
# label blobs
from scipy import ndimage
lab, n = ndimage.label(mask)
print("blobs:", n)
sizes = ndimage.sum(mask, lab, range(1, n+1))
order = np.argsort(sizes)[::-1][:8]
for i in order:
    idx = i+1
    ys, xs = np.where(lab == idx)
    cx, cy = xs.mean(), ys.mean()
    rad = np.sqrt(sizes[i]/np.pi)
    if rad < 20: continue
    print("blob size=%7d centre=(%7.1f,%7.1f) radius_px=%6.1f  diameter_px=%6.1f" % (sizes[i], cx, cy, rad, rad*2))
