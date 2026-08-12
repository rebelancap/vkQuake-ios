import struct, sys, os
def entries(path):
    with open(path,'rb') as f:
        hdr=f.read(12)
        if hdr[:4]!=b'PACK': raise SystemExit('not a pak: '+path)
        ofs,ln=struct.unpack('<ii',hdr[4:])
        f.seek(ofs); data=f.read(ln)
    out=[]
    for i in range(ln//64):
        rec=data[i*64:(i+1)*64]
        name=rec[:56].split(b'\0')[0].decode('latin-1')
        fo,fl=struct.unpack('<ii',rec[56:64])
        out.append((name,fo,fl))
    return out
if __name__=='__main__':
    pak=sys.argv[1]
    if len(sys.argv)==2:
        for n,o,l in sorted(entries(pak),key=lambda e:e[2]):
            if n.lower().endswith('.bsp'): print(l,n)
    else:
        want=sys.argv[2].lower(); dest=sys.argv[3]
        for n,o,l in entries(pak):
            if n.lower()==want:
                with open(pak,'rb') as f:
                    f.seek(o); d=f.read(l)
                open(dest,'wb').write(d)
                print('wrote',dest,len(d)); break
        else: raise SystemExit('not found: '+want)
