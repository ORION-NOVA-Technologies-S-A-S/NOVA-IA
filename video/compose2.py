import json, subprocess, textwrap
from PIL import Image, ImageDraw, ImageFont, ImageFilter
PH='/root/.claude/uploads/98897fea-0b6f-5cea-bd85-e2ba64bdc232/019134e1-image.jpg'
FONT='/usr/share/fonts/opentype/inter/Inter-Medium.otf'; FB='/usr/share/fonts/opentype/inter/Inter-Bold.otf'
LOGO=None
d=json.load(open('marks.json')); marks=d['marks']; dur=d['dur']
W,H=1280,720; INTRO=4.5; OUTRO=5.0
# --- foto circular con aro
ph=Image.open(PH).convert('RGB').crop((155,60,675,580)).resize((300,300),Image.LANCZOS)
def ring(sz,photo):
    S=sz+20; im=Image.new('RGBA',(S,S),(0,0,0,0)); dr=ImageDraw.Draw(im)
    glow=Image.new('RGBA',(S,S),(0,0,0,0)); ImageDraw.Draw(glow).ellipse((2,2,S-2,S-2),fill=(76,125,255,170)); glow=glow.filter(ImageFilter.GaussianBlur(5)); im.alpha_composite(glow)
    dr.ellipse((6,6,S-6,S-6),fill=(255,255,255,255))
    m=Image.new('L',(sz,sz),0); ImageDraw.Draw(m).ellipse((0,0,sz-1,sz-1),fill=255)
    p=photo.resize((sz,sz),Image.LANCZOS).convert('RGBA'); p.putalpha(m); im.alpha_composite(p,(10,10)); return im
ring(150,ph).save('badge.png'); ring(240,ph).save('badge_big.png')
def bg():
    im=Image.new('RGB',(W,H),(5,6,16)); dr=ImageDraw.Draw(im)
    g=Image.new('RGB',(W,H),(5,6,16)); gd=ImageDraw.Draw(g); gd.ellipse((380,-200,1180,500),fill=(28,40,120)); g=g.filter(ImageFilter.GaussianBlur(160)); return g
def card(name,title,sub,small,photo_big=True):
    im=bg(); dr=ImageDraw.Draw(im)
    f1=ImageFont.truetype(FB,64); f2=ImageFont.truetype(FONT,30); f3=ImageFont.truetype(FONT,22); fs=ImageFont.truetype(FB,20)
    b=Image.open('badge_big.png'); im.paste(b,(150,230),b)
    dr.text((470,230),'NOVA',font=fs,fill=(110,160,255),spacing=6)
    y=262
    for l in textwrap.wrap(title,22): dr.text((470,y),l,font=f1,fill=(240,243,255)); y+=76
    for l in textwrap.wrap(sub,46): dr.text((470,y+14),l,font=f2,fill=(160,170,210)); y+=40
    dr.text((470,H-100),small,font=f3,fill=(110,120,170))
    im.save(name)
card('intro.png','Así funciona Nova','Pedidos, pagos y reservas para restaurantes y hoteles de Neiva.','Orion Nova Technologies  ·  Demostración con datos de prueba')
card('outro.png','Nova atiende mesas y habitaciones','orion-nova-technologies-s-a-s.github.io/NOVA-IA','Orion Nova Technologies')
# --- subtítulos
def esc(t): return t.replace("\\","\\\\").replace(":","\\:").replace("'","’").replace("%","\\%").replace(",","\\,")
caps=[]
for i,m in enumerate(marks):
    a=m['t']; b=(marks[i+1]['t'] if i+1<len(marks) else dur)-0.1
    lines=textwrap.wrap(m['text'],58)
    caps.append((a,b,lines))
vf=[]
inp='[0:v]format=yuv420p,fps=30[v0]'
parts=[inp]; cur='v0'
for k,(a,b,lines) in enumerate(caps):
    for j,l in enumerate(lines):
        y=H-110+j*40-(len(lines)-1)*20
        nxt=f'c{k}_{j}'
        parts.append(f"[{cur}]drawtext=fontfile={FONT}:text='{esc(l)}':fontcolor=white:fontsize=30:box=1:boxcolor=0x05061099:boxborderw=14:x=(w-text_w)/2:y={y}:enable='between(t,{a:.2f},{b:.2f})'[{nxt}]"); cur=nxt
parts.append(f"[{cur}][1:v]overlay=24:{H-182}:enable='gte(t,0.5)'[vb]")
parts.append(f"[vb]drawtext=fontfile={FB}:text='DEMO · datos de prueba':fontcolor=0x9db4ff:fontsize=16:x=w-text_w-24:y=18:enable='between(t,0,{dur})'[vm]")
fc=';'.join(parts)
open('fc.txt','w').write(fc)

subprocess.run(['ffmpeg','-y','-v','error','-i','raw.webm','-i','badge.png','-filter_complex',fc,'-map','[vm]','-t',str(dur),'-r','30','-c:v','libx264','-crf','21','-pix_fmt','yuv420p','mid.mp4'],check=True)
for n,t in (('intro',INTRO),('outro',OUTRO)):
    subprocess.run(['ffmpeg','-y','-v','error','-loop','1','-t',str(t),'-i',n+'.png','-vf','fps=30,format=yuv420p,fade=t=in:st=0:d=0.5,fade=t=out:st=%s:d=0.5'%(t-0.5),'-c:v','libx264','-crf','21',n+'.mp4'],check=True)
open('list.txt','w').write("file 'intro.mp4'\nfile 'mid.mp4'\nfile 'outro.mp4'\n")
subprocess.run(['ffmpeg','-y','-v','error','-f','concat','-i','list.txt','-c','copy','nova_demo.mp4'],check=True)
