FROM rockylinux:9 AS build
RUN dnf -y install epel-release dnf-plugins-core && dnf config-manager --set-enabled crb && \
    dnf -y install gcc git ninja-build pkgconf-pkg-config python3-pip flex bison xkbcomp cpio \
      xorg-x11-proto-devel xorg-x11-xtrans-devel pixman-devel libxkbfile-devel libXfont2-devel \
      libXdmcp-devel libXau-devel libX11-devel libxcb-devel libdrm-devel libepoxy-devel \
      mesa-libgbm-devel mesa-libGL-devel mesa-libEGL-devel libxshmfence-devel libselinux-devel \
      audit-libs-devel libbsd-devel libxcvt-devel libtirpc-devel nettle-devel && \
    pip3 install meson
RUN git clone --depth 1 --branch xlibre-xserver-25.2.2 https://github.com/X11Libre/xserver /xlibre && \
    cd /xlibre && meson setup build --prefix=/opt/xlibre -Dxorg=false -Dxephyr=false -Dxnest=false \
      -Dxvfb=true -Dglamor=true -Dxkb_dir=/usr/share/X11/xkb -Dxkb_bin_dir=/usr/bin -Dxkb_output_dir=/tmp && \
    ninja -C build && meson install -C build
RUN mkdir -p /opt/nvidia-el9 && cd /opt/nvidia-el9 && dnf download egl-gbm && \
    rpm2cpio egl-gbm-*.rpm | cpio -idm && rm -f egl-gbm-*.rpm && \
    LIB=$(ls /opt/nvidia-el9/usr/lib64/libnvidia-egl-gbm.so.1.* | head -1) && \
    printf '{\n  "file_format_version": "1.0.0",\n  "ICD": { "library_path": "%s" }\n}\n' "$LIB" > 15_nvidia_gbm.json

FROM rockylinux:9
RUN dnf -y install epel-release dnf-plugins-core && dnf config-manager --set-enabled crb && \
    dnf -y install systemd python3-pip xkbcomp xkeyboard-config libxkbcommon libglvnd-egl libglvnd-glx \
      libglvnd-opengl mesa-libgbm mesa-libGL mesa-libEGL mesa-dri-drivers libdrm libwayland-server \
      libepoxy libXfont2 libbsd libxshmfence pixman libXdmcp libXau libX11 libXext libXfixes libXtst \
      libXdamage libXcomposite libXrandr glx-utils xorg-x11-utils xterm openbox xorg-x11-server-Xorg xrandr xorg-x11-fonts-misc which && \
    dnf -y --setopt=strict=0 install xrandr xhost xset xrdb pulseaudio-libs procps-ng less && \
    dnf clean all && pip3 install selkies
COPY --from=build /opt/xlibre /opt/xlibre
COPY --from=build /opt/nvidia-el9 /opt/nvidia-el9
RUN useradd -u 1000 -m rocky && mkdir -p /etc/selkies
COPY gpu.env /etc/selkies/gpu.env
COPY tmpfiles.conf /etc/tmpfiles.d/selkies.conf
COPY start-xvfb wait-x start-session /usr/local/bin/
COPY xvfb.service selkies.service session.service /etc/systemd/system/
RUN chmod 755 /usr/local/bin/start-xvfb /usr/local/bin/wait-x /usr/local/bin/start-session && \
    systemctl enable xvfb.service selkies.service session.service && \
    systemctl set-default multi-user.target
CMD ["/sbin/init"]
