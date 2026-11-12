# Raspberry Pi setup

Tested design target: Raspberry Pi OS Bookworm or Trixie (Debian 12/13), Pi 3B through Pi 5.
No compiled modules are needed. The app uses only interfaces that the kernel and Raspberry Pi OS already provide.

| Part    | Interface | Why |
|---------|-----------|-----|
| Sensor  | kernel `dht11` IIO driver | DHT timing is done in the kernel, so it works on every model, including the Pi 5 (where bcm2835-based libraries don't) |
| Buttons | `gpiomon` from libgpiod (v1 or v2, auto-detected) | edge events; the old sysfs GPIO interface (`onoff`) is deprecated |
| Relays  | `pinctrl set <pin> op dh/dl` | the pin keeps its level without a process holding it; `raspi-gpio` has the same syntax on older OS releases |

## 1. Sensor overlay

Add this line to `/boot/firmware/config.txt` (on older releases: `/boot/config.txt`) and reboot:

```
dtoverlay=dht11,gpiopin=4
```

The driver handles both the DHT11 and the DHT22/AM2302. Check that it works:

```sh
cat /sys/bus/iio/devices/iio:device0/name          # dht11
cat /sys/bus/iio/devices/iio:device0/in_temp_input  # millidegrees, e.g. 21300
```

Occasional `Input/output error` or `Connection timed out` errors are normal for this sensor. The app just retries. It pauses the heater only if no reading succeeds for `sensor_timeout` seconds (default 60).

## 2. Packages and user

```sh
sudo apt install libmojolicious-perl gpiod
sudo useradd --system --home /opt/dryer --groups gpio dryer
sudo git clone https://github.com/uniejo/raspi-humid-blynk.git /opt/dryer
sudo cp /opt/dryer/dryer.conf.example /opt/dryer/dryer.conf
sudo chown -R dryer:dryer /opt/dryer
```

Debian's `libmojolicious-perl` must be 9.34 or newer (Trixie has it). On Bookworm, install a newer Mojolicious with `cpanm Mojolicious` if needed.

Edit `/opt/dryer/dryer.conf`:
- Set `hardware => 'Pi'`.
- Set a `password`.
- Optionally set `notify` (ntfy topic and/or email).

Check the pins and the relay polarity before connecting the heater:

```sh
pinctrl get 17,18,22,23,24,27
gpiomon -c gpiochip0 17 23        # press the buttons (libgpiod v1: gpiomon gpiochip0 17 23)
pinctrl set 27 op dh; sleep 1; pinctrl set 27 op dl   # clicker relay
```

If a relay is *on* when the pin is low, add `active_low => 1` to that output in `dryer.conf`.
If the buttons have no pull-up resistors, set `bias => 'pull-up'`.

## 3. Service

```sh
sudo cp /opt/dryer/etc/dryer.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dryer
journalctl -u dryer -f
```

Open `http://<pi>:3000/`.

Safety notes:
- The app switches every relay off on stop or SIGTERM. The unit's `ExecStopPost` also forces the heater pin low after a crash. If you change the heater pin, update that line too.
- The app must run as a **single process** (`daemon`). Prefork/hypnotoad would start several processes that all drive the same pins.
- The UI can switch a heater. Keep it on the LAN, or behind a reverse proxy with TLS, and always set a password.

## Migrating from humid_blynk.js

Copy the old save file and point `save_file` at it, or rename it to `dryer-state.json`:

```sh
cp humid_blynk.json /opt/dryer/dryer-state.json
```

The settings and running degree-day timers are loaded, and the old millisecond timestamps are converted. From then on, the file is saved in the new format.

## Differences from the 2016 version

- Blynk is replaced by the built-in web UI (WebSocket live updates and a 24 h chart).
- Email from Blynk is replaced by ntfy and/or local sendmail.
- The heater is paused when the sensor stops answering (the old script kept heating).
- Fixed: timer warnings are sent one at a time (before, all of them fired together at "1 degree-day remaining" and the timer was deleted early).
- Fixed: the degree-days setting survives a restart.
- Fixed: the save happens every 15 min (it was every 90 s).
- Fixed: a missing save file at the first start no longer crashes the script.
- The unused "cool" stage is gone. The fan relay is held off.
