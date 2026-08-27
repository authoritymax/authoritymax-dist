FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb \
    x11vnc \
    fluxbox \
    xterm \
    xdotool \
    x11-utils \
    x11-xserver-utils \
    imagemagick \
    novnc \
    websockify \
    python3 \
    ca-certificates \
    procps \
    bash \
    chromium \
    fonts-liberation \
    fonts-dejavu-core \
    dbus-x11 \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /etc/authoritymax/fluxbox \
  && printf '%s\n' '#!/bin/sh' 'exec xsetroot -solid "#111113" "$@"' > /usr/bin/fbsetbg \
  && chmod +x /usr/bin/fbsetbg \
  && ln -sfn /bin/true /usr/bin/xmessage
ENV DISPLAY=:1
ENV HOME=/home/authoritymax
WORKDIR /home/authoritymax
COPY start.sh /usr/local/bin/authoritymax-computer
COPY authoritymax-browser /usr/local/bin/authoritymax-browser
COPY fluxbox.init /etc/authoritymax/fluxbox/init
COPY fluxbox.apps /etc/authoritymax/fluxbox/apps
COPY fluxbox.menu /etc/authoritymax/fluxbox/menu
COPY embed.html /usr/share/novnc/embed.html
# Strip CR so shebangs work even if the build context came from a CRLF checkout.
RUN sed -i 's/\r$//' /usr/local/bin/authoritymax-computer /usr/local/bin/authoritymax-browser \
    /etc/authoritymax/fluxbox/init /etc/authoritymax/fluxbox/apps /etc/authoritymax/fluxbox/menu \
  && chmod +x /usr/local/bin/authoritymax-computer /usr/local/bin/authoritymax-browser
EXPOSE 6080 6081 6082 6083 6084 6085 6086 6087 6088 6089 6090 6091 6092 6093 6094 6095
CMD ["/usr/local/bin/authoritymax-computer"]
