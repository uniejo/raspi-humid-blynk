# raspi-humid-blynk – Raspberry Pi dryer

Humidity/temperature control on a Raspberry Pi. It heats an object to dry it:

- The **heater relay** is on until the target humidity is reached, without going over a max temperature.
- When the humidity has stayed at the target for a minute, the stage is **done**.
- **Degree-day timers** track several items in storage (sum of °C × days). Each timer sends warnings at 1 and ½ degree-day before its target, at the target, and ½ after.

The app is controlled from a phone-friendly web page and two physical buttons. Notices are sent by [ntfy](https://ntfy.sh) and/or email.

> **Version 2 (2026)** replaces the original 2016 Node.js/Blynk script, kept in
> [`legacy/humid_blynk.js`](legacy/humid_blynk.js) for reference. The legacy Blynk cloud and app
> no longer exist, so the app is now a small self-hosted
> [Mojolicious](https://mojolicious.org) daemon. Old `humid_blynk.json` save files can be loaded
> (see [migration](docs/raspberry-pi-setup.md#migrating-from-humid_blynkjs)).

## Hardware

Raspberry Pi (any model with the 40-pin header, Pi 3B or later), relay board, and a proto board with two buttons and a DHT11/DHT22 sensor.

| Function            | BCM GPIO | Notes                                   |
|---------------------|---------:|-----------------------------------------|
| DHT11/DHT22 data    | 4        | read by the kernel `dht11` driver       |
| Start/stop button   | 23       | short press: start · long (≥1.5 s): stop |
| Timer button        | 17       | short press: add timer · long (≥1 s): remove newest |
| Heater relay        | 18       | on while stage is *heating*             |
| Fan relay           | 24       | held off (not used yet)                 |
| Clicker relay       | 27       | clicks as feedback and on timer warnings |
| Spare relay         | 22       | held off                                |

Pins are configurable in `dryer.conf`. PDFs with the original build:

- [Overview](docs/Raspberry_Pi_dryer_overview.pdf)
- [Proto board](docs/Raspberry_Pi_dryer_hardware_proto.pdf), with [schematics](docs/Raspberry_Pi_dryer_hardware_proto_schematics.pdf)
- [Relay board](docs/Raspberry_Pi_dryer_hardware_relay.pdf)
- [Assembling](docs/Raspberry_Pi_dryer_hardware_assembling.pdf)
- [Blynk UI (historical)](docs/Raspberry_Pi_dryer_blynk.pdf)

## Quick start (no Pi needed)

```sh
cpanm --installdeps .
script/dryer daemon -l http://127.0.0.1:3000   # simulated hardware by default
prove -l t/
```

Open <http://127.0.0.1:3000>. With the default `Mock` hardware, the dryer is simulated: it heats and dries about 10× faster than real time.

## On the Raspberry Pi

See [docs/raspberry-pi-setup.md](docs/raspberry-pi-setup.md). In short:

1. Add `dtoverlay=dht11,gpiopin=4` to the boot config.
2. Install the packages: `apt install libmojolicious-perl gpiod`.
3. Copy `dryer.conf.example` to `dryer.conf` and set `hardware => 'Pi'` and a password.
4. Install `etc/dryer.service` as a systemd unit.

## Layout

```
script/dryer                 start script (Mojolicious commands: daemon, routes, ...)
lib/Dryer.pm                 app: config, wiring, routes, main loop
lib/Dryer/Model.pm           drying state machine, degree-day timers, persistence
lib/Dryer/Buttons.pm         press/hold detection with debounce
lib/Dryer/Hardware/Pi.pm     IIO sensor, gpiomon buttons, pinctrl relays
lib/Dryer/Hardware/Mock.pm   simulated dryer for development and tests
lib/Dryer/Notifier.pm        ntfy and email notices
lib/Dryer/Controller/Api.pm  JSON API and WebSocket
templates/, public/          web UI
etc/dryer.service            systemd unit
```

## API

All endpoints are behind the optional password (HTTP basic auth).

| Method | Path                     | |
|--------|--------------------------|-|
| GET    | `/api/state`             | current state (all other endpoints return it too) |
| GET    | `/api/history`           | last 24 h, one `[time, temperature, humidity]` per minute |
| POST   | `/api/heat/start`        | start drying |
| POST   | `/api/heat/stop`         | stop (back to *ready*) |
| POST   | `/api/timers`            | add a degree-day timer |
| DELETE | `/api/timers/newest`     | remove newest timer (`/oldest` for oldest) |
| PUT    | `/api/settings`          | JSON with any of `req_humid`, `max_temp`, `req_temp_days` |
| WS     | `/ws`                    | pushes the state on every change |

## License

GPL-3.0, see [LICENSE](LICENSE).
