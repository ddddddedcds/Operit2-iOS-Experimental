# iOS (Theos) Tweak

Theos tweak scaffold. Build and install on-device when theos is installed
(set `THEOS_DEVICE_IP` / `THEOS_DEVICE_PORT` in the Makefile, or export them).

Commands:
- `make` — build
- `make package` — build .deb
- `make package install` — build and install to device
- `make clean` — clean

Edit `Tweak.xm`, `Makefile`, and `control` to suit your tweak.
