FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb x11vnc fluxbox xterm tmux xdotool x11-utils x11-xserver-utils \
    imagemagick novnc websockify python3 ca-certificates curl gnupg procps bash tar tzdata \
    pcmanfm tint2 hsetroot adwaita-icon-theme-legacy xdg-utils shared-mime-info desktop-file-utils file \
    fonts-liberation fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji \
    fonts-freefont-ttf fonts-crosextra-carlito fonts-crosextra-caladea \
    dbus-x11 \
  && if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
       curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
         | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
       && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
         > /etc/apt/sources.list.d/google-chrome.list \
       && apt-get update && apt-get install -y --no-install-recommends google-chrome-stable \
       && install -D -m 0644 /usr/share/icons/hicolor/128x128/apps/google-chrome.png \
            /usr/share/icons/hicolor/128x128/apps/authoritymax-browser.png; \
     else \
       apt-get install -y --no-install-recommends chromium \
       && install -D -m 0644 /usr/share/icons/hicolor/128x128/apps/chromium.png \
            /usr/share/icons/hicolor/128x128/apps/authoritymax-browser.png; \
     fi \
  && apt-get purge -y curl gnupg && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /etc/authoritymax/fluxbox /usr/share/authoritymax \
  && printf '%s\n' '#!/bin/sh' 'exec hsetroot -fill /usr/share/authoritymax/wallpaper.png' > /usr/bin/fbsetbg \
  && chmod +x /usr/bin/fbsetbg \
  && ln -sfn /bin/true /usr/bin/xmessage
ENV DISPLAY=:1
ENV HOME=/home/authoritymax
ENV BROWSER=/usr/local/bin/authoritymax-browser
WORKDIR /home/authoritymax
COPY wallpaper-mark.png /usr/share/authoritymax/wallpaper-mark.png
# Wallpaper: dark radial gradient in the app's page tones with the mark faded into it.
# Generated here so the repo carries no 1280x800 binary; muted so screenshots stay clean.
# The mark PNG is opaque, so its own alpha channel is a radial mask (no square edge)
# scaled to 35 % — plain opacity on a channel that does not exist would be a no-op.
RUN convert -size 1280x800 radial-gradient:'#1c2033'-'#0f1016' /usr/share/authoritymax/wallpaper-base.png \
  && convert -size 160x160 radial-gradient:white-black -alpha off /usr/share/authoritymax/wallpaper-mask.png \
  && convert /usr/share/authoritymax/wallpaper-mark.png -resize 160x160 \
       /usr/share/authoritymax/wallpaper-mask.png -alpha off -compose CopyOpacity -composite \
       -channel A -evaluate multiply 0.35 +channel /usr/share/authoritymax/wallpaper-glyph.png \
  && convert /usr/share/authoritymax/wallpaper-base.png /usr/share/authoritymax/wallpaper-glyph.png \
       -gravity center -compose over -composite /usr/share/authoritymax/wallpaper.png \
  && rm /usr/share/authoritymax/wallpaper-base.png /usr/share/authoritymax/wallpaper-mask.png \
       /usr/share/authoritymax/wallpaper-glyph.png
COPY start.sh /usr/local/bin/authoritymax-computer
COPY authoritymax-browser /usr/local/bin/authoritymax-browser
COPY authoritymax-launch /usr/local/bin/authoritymax-launch
COPY authoritymax-terminal-tty /usr/local/bin/authoritymax-terminal-tty
COPY authoritymax-terminal /usr/local/bin/authoritymax-terminal
COPY authoritymax-browser.desktop authoritymax-files.desktop authoritymax-terminal.desktop /usr/share/applications/
COPY mimeapps.list /etc/xdg/mimeapps.list
COPY tint2rc /etc/authoritymax/tint2rc
COPY fluxbox.init /etc/authoritymax/fluxbox/init
COPY fluxbox.apps /etc/authoritymax/fluxbox/apps
COPY fluxbox.menu /etc/authoritymax/fluxbox/menu
COPY embed.html /usr/share/novnc/embed.html
# Strip CR so shebangs work even if the build context came from a CRLF checkout.
RUN sed -i 's/\r$//' /usr/local/bin/authoritymax-computer /usr/local/bin/authoritymax-browser /usr/local/bin/authoritymax-launch \
    /usr/local/bin/authoritymax-terminal-tty /usr/local/bin/authoritymax-terminal /etc/authoritymax/tint2rc \
    /etc/authoritymax/fluxbox/init /etc/authoritymax/fluxbox/apps /etc/authoritymax/fluxbox/menu \
  && chmod +x /usr/local/bin/authoritymax-computer /usr/local/bin/authoritymax-browser /usr/local/bin/authoritymax-launch \
    /usr/local/bin/authoritymax-terminal-tty /usr/local/bin/authoritymax-terminal \
  && update-desktop-database /usr/share/applications
EXPOSE 6080 6081 6082 6083 6084 6085 6086 6087 6088 6089 6090 6091 6092 6093 6094 6095
CMD ["/usr/local/bin/authoritymax-computer"]
