#!/bin/sh
set -eu
cd "$(dirname "$0")"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'color=c=0x020916:s=960x540:r=20:d=3' \
  -loop 1 -framerate 20 -i cloudcodex-startup-title.png \
  -filter_complex "[0:v]drawbox=x=240:y=269:w=480:h=2:color=0x69ddff:t=fill,fade=t=in:st=0:d=0.25[intro];[1:v]scale=1920:1080,zoompan=z='1.06-0.06*min(on/24,1)':x='iw/2-iw/zoom/2':y='ih/2-ih/zoom/2':d=1:s=960x540:fps=20,format=yuv420p[title];[intro][title]xfade=transition=fade:duration=0.45:offset=0.25,trim=duration=3,setpts=PTS-STARTPTS,split[a][b];[a]palettegen=stats_mode=full: max_colors=192[p];[b][p]paletteuse=dither=sierra2_4a" \
  -t 3 -loop 0 cloudcodex-startup.gif
